import Foundation
import Observation
import OSLog
import WatchConnectivity
import WatchKit

/// The phone persists workouts; pending edits replay over each accepted authoritative base.
@Observable @MainActor
final class WatchSessionClient: NSObject, WCSessionDelegate {
    private(set) var state = WatchWorkoutState(templates: [], active: nil, unitRaw: "lb", revision: 0)
    private(set) var isReachable = false
    private(set) var isConnected = false
    private(set) var hasReceivedContext = false
    private(set) var hasPendingActions = false
    private(set) var terminalWorkoutID: UUID?
    private(set) var savedConfirmed = false
    var showSaved = false {
        didSet { if !showSaved { reconciler.dismissSaved() } }
    }
    var errorMessage: String? {
        didSet { if errorMessage == nil { reconciler.clearError() } }
    }

    @ObservationIgnored private var reconciler = WatchWorkoutReconciler(
        baseState: .init(templates: [], active: nil, unitRaw: "lb", revision: 0))

    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private let alerts = WatchRestAlerts()
    @ObservationIgnored private var isFixture = false
    @ObservationIgnored private var alertedRestTimerIDs: Set<UUID> = []
    nonisolated private static let logger = Logger(subsystem: "com.liftlog.app.watchkitapp", category: "WatchSession")

    override init() {
        super.init()
        #if DEBUG
        if let fixture = WatchPreviewFixture.state(arguments: ProcessInfo.processInfo.arguments) {
            isFixture = true
            reconciler = WatchWorkoutReconciler(baseState: fixture)
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
        var visible = state
        visible.active = visibleWorkout
        return visible
    }

    @discardableResult
    func completeSet(setID: UUID, weight: Double, reps: Int) -> Bool {
        let completedAt = Date()
        let restTimerID = UUID()
        return send(.completeSet(setID: setID, weight: weight, reps: reps,
                                 completedAt: completedAt, restTimerID: restTimerID))
    }

    @discardableResult
    func send(_ action: WatchAction) -> Bool {
        guard isFixture || session?.activationState == .activated else {
            errorMessage = "Open Lift Log on iPhone and try again."
            return false
        }
        let request = WatchActionRequest(operationID: UUID(), action: action)
        do {
            let dictionary = try WatchWorkoutTransport.encode(request: request)
            reconciler.enqueue(request)
            publishProjection()
            if isFixture {
                #if DEBUG
                applyFixtureAction(request)
                #endif
            } else {
                // One durable FIFO for reachable and offline actions alike.
                session?.transferUserInfo(dictionary)
            }
            refreshConnection()
            return true
        } catch {
            Self.logger.error("Watch action encoding failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn’t send this change. Try again."
            return false
        }
    }

    private func publishProjection() {
        // Never expose the raw base between receipt retirement and pending replay.
        state = reconciler.state
        terminalWorkoutID = reconciler.terminalWorkoutID
        savedConfirmed = reconciler.savedConfirmed
        showSaved = reconciler.showSaved
        if let message = reconciler.errorMessage { errorMessage = message }
        hasPendingActions = !reconciler.pending.isEmpty || !(session?.outstandingUserInfoTransfers.isEmpty ?? true)
    }

    func synchronizeAlerts() async {
        guard !isFixture else { return }
        await alerts.synchronize(state: alertState, isReachable: isReachable)
    }

    func refreshConnection() {
        hasPendingActions = !reconciler.pending.isEmpty || !(session?.outstandingUserInfoTransfers.isEmpty ?? true)
        guard let session else { return }
        isReachable = session.isReachable
        isConnected = session.activationState == .activated
    }

    func restDidExpire(id: UUID) {
        guard let workout = visibleWorkout, workout.restTimerID == id,
              let deadline = workout.restEndsAt, alertedRestTimerIDs.insert(id).inserted else { return }
        // Opening a workout long after rest ended must not replay an old alert,
        // but it still advances straight to the next set without a tap.
        if Date().timeIntervalSince(deadline) <= 60 {
            WKInterfaceDevice.current().play(.notification)
        }
        if let action = alertState.restExpiryAction(at: Date()) { send(action) }
    }

    private func accept(_ incoming: WatchWorkoutState) {
        guard reconciler.accept(incoming) else { return }
        publishProjection()
        hasReceivedContext = true
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
        let operationID = (try? WatchWorkoutTransport.decodeRequest(from: userInfoTransfer.userInfo))?.operationID
        if let error { Self.logger.error("Queued Watch action failed: \(error.localizedDescription, privacy: .public)") }
        let failed = error != nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            if failed, let operationID, self.reconciler.fail(operationID: operationID) {
                self.publishProjection()
            }
            self.refreshConnection()
        }
    }

    #if DEBUG
    private func applyFixtureAction(_ request: WatchActionRequest) {
        // Hold the synthetic finish to exercise the unconfirmed presentation offline.
        if WatchPreviewFixture.screen == "saving", case .finish = request.action { return }
        var incoming = reconciler.state
        switch request.action {
        case .startEmpty, .startTemplate:
            incoming.active = WatchPreviewFixture.workoutState(resting: false).active
        case .finish, .discard:
            incoming.active = nil
        default: break
        }
        incoming.publicationSequence += 1
        incoming.processedThroughOperationID = request.operationID
        if let result = WatchTerminalResult(request: request, succeeded: true) {
            incoming.lastTerminalResult = result
        }
        accept(incoming)
    }
    #endif
}
