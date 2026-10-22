import Foundation
import Observation
import OSLog
import WatchConnectivity
import WatchKit

/// The phone remains the only persistence owner. The mirror lasts only until the next snapshot.
@Observable @MainActor
final class WatchSessionClient: NSObject, WCSessionDelegate {
    private(set) var state = WatchWorkoutState(templates: [], active: nil, unitRaw: "lb", revision: 0)
    private(set) var isReachable = false
    private(set) var isConnected = false
    private(set) var hasReceivedContext = false
    private(set) var hasPendingActions = false
    private(set) var terminalWorkoutID: UUID?
    var showSaved = false
    var errorMessage: String?

    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private let alerts = WatchRestAlerts()
    @ObservationIgnored private var isFixture = false
    @ObservationIgnored private var alertedRestTimerIDs: Set<UUID> = []
    @ObservationIgnored private var latestSendID: UUID?
    @ObservationIgnored private var terminalRevision: UInt64?
    nonisolated private static let sendIDKey = "watchSendID"
    nonisolated private static let logger = Logger(subsystem: "com.liftlog.app.watchkitapp", category: "WatchSession")

    override init() {
        super.init()
        #if DEBUG
        if let fixture = WatchPreviewFixture.state(arguments: ProcessInfo.processInfo.arguments) {
            isFixture = true
            state = fixture
            hasReceivedContext = WatchPreviewFixture.screen != "unavailable"
            isConnected = true
            isReachable = true
            return
        }
        #endif
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    var visibleWorkout: WatchActiveWorkout? {
        guard state.active?.id != terminalWorkoutID else { return nil }
        return state.active
    }

    var alertState: WatchWorkoutState {
        .init(templates: state.templates, active: visibleWorkout, unitRaw: state.unitRaw, revision: state.revision)
    }

    @discardableResult
    func send(_ action: WatchAction) -> Bool {
        if isFixture {
            state = state.applyingOptimistically(action, at: Date(), newTimerID: UUID())
            #if DEBUG
            applyFixtureAction(action)
            #endif
            return true
        }
        guard let session, session.activationState == .activated else {
            errorMessage = "Open Lift Log on iPhone and try again."
            return false
        }
        do {
            var dictionary = try WatchWorkoutTransport.encode(action: action)
            let sendID = UUID()
            latestSendID = sendID
            dictionary[Self.sendIDKey] = sendID.uuidString
            state = state.applyingOptimistically(action, at: Date(), newTimerID: UUID())
            switch action {
            case .finish(let id):
                terminalWorkoutID = id
                terminalRevision = state.revision
                showSaved = true
            case .discard(let id):
                terminalWorkoutID = id
                terminalRevision = state.revision
            default: break
            }
            // All actions share the durable FIFO queue, including while reachable, so a
            // finish cannot overtake a queued set edit. The ID only correlates local errors;
            // it is not an operation ID or a retry/deduplication protocol on the phone.
            session.transferUserInfo(dictionary)
            refreshConnection()
            return true
        } catch {
            Self.logger.error("Watch action encoding failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn’t send this change. Try again."
            return false
        }
    }

    func synchronizeAlerts() async {
        guard !isFixture else { return }
        await alerts.synchronize(state: alertState, isReachable: isReachable)
    }

    func refreshConnection() {
        guard let session else { return }
        isReachable = session.isReachable
        isConnected = session.activationState == .activated
        hasPendingActions = !session.outstandingUserInfoTransfers.isEmpty
    }

    func restDidExpire(id: UUID) {
        guard let workout = visibleWorkout, workout.restTimerID == id,
              let deadline = workout.restEndsAt, alertedRestTimerIDs.insert(id).inserted else { return }
        // Opening a workout long after rest ended must not replay an old alert.
        guard Date().timeIntervalSince(deadline) <= 60 else { return }
        WKInterfaceDevice.current().play(.notification)
    }

    private func accept(_ incoming: WatchWorkoutState) {
        // Equality is the only filter: the phone's revision counter resets on relaunch.
        if incoming != state { state = incoming }
        hasReceivedContext = true
        if let terminalWorkoutID, incoming.active?.id == terminalWorkoutID {
            // An in-flight pre-finish snapshot is not a rejection of the terminal action.
            guard incoming.revision != terminalRevision else { return }
            clearTerminalAction()
            errorMessage = "iPhone still has this workout open. Review it and try again."
        } else if incoming.active != nil {
            clearTerminalAction()
        }
    }

    private func clearTerminalAction() {
        terminalWorkoutID = nil
        terminalRevision = nil
        latestSendID = nil
        showSaved = false
    }

    nonisolated private func receive(_ dictionary: [String: Any]) {
        do {
            let incoming = try WatchWorkoutTransport.decodeState(from: dictionary)
            Task { @MainActor [weak self] in self?.accept(incoming) }
        } catch {
            Self.logger.error("Watch snapshot rejected: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error { Self.logger.error("Watch activation failed: \(error.localizedDescription, privacy: .public)") }
        if !session.receivedApplicationContext.isEmpty { receive(session.receivedApplicationContext) }
        Task { @MainActor [weak self] in
            self?.refreshConnection()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refreshConnection() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receive(userInfo)
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        let sendID = (userInfoTransfer.userInfo[Self.sendIDKey] as? String).flatMap(UUID.init(uuidString:))
        let failedWorkoutID: UUID?
        // Decode on the delegate queue; only value types cross to the main actor.
        switch try? WatchWorkoutTransport.decodeAction(from: userInfoTransfer.userInfo) {
        case .finish(let id), .discard(let id): failedWorkoutID = id
        default: failedWorkoutID = nil
        }
        if let error { Self.logger.error("Queued Watch action failed: \(error.localizedDescription, privacy: .public)") }
        let failed = error != nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshConnection()
            guard failed else { return }
            if let sendID, self.latestSendID == sendID, let failedWorkoutID,
               self.terminalWorkoutID == failedWorkoutID {
                self.clearTerminalAction()
            }
            self.errorMessage = "A queued change couldn’t sync. Check your workout on iPhone."
        }
    }

    #if DEBUG
    private func applyFixtureAction(_ action: WatchAction) {
        switch action {
        case .startEmpty, .startTemplate:
            state = WatchPreviewFixture.workoutState(resting: false)
        case .finish(let id):
            terminalWorkoutID = id
            showSaved = true
        case .discard(let id): terminalWorkoutID = id
        default: break
        }
    }
    #endif
}
