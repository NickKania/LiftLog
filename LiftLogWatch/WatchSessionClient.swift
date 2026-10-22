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
        didSet {
            if !showSaved && reconciler.showSaved {
                var updated = reconciler
                updated.dismissSaved()
                _ = commit(updated)
            }
        }
    }
    var errorMessage: String? {
        didSet { if errorMessage == nil { reconciler.clearError() } }
    }

    @ObservationIgnored private var reconciler = WatchWorkoutReconciler(
        baseState: .init(templates: [], active: nil, unitRaw: "lb", revision: 0))

    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private var hasActivatedSession = false
    @ObservationIgnored private let journal: WatchWorkoutJournal
    @ObservationIgnored private var journalIsReadable = true
    @ObservationIgnored private let alerts = WatchRestAlerts()
    @ObservationIgnored private var isFixture = false
    @ObservationIgnored private var alertedRestTimerIDs: Set<UUID> = []
    nonisolated private static let logger = Logger(subsystem: "com.liftlog.app.watchkitapp", category: "WatchSession")

    init(journal: WatchWorkoutJournal = .init(url: URL.applicationSupportDirectory
        .appendingPathComponent("LiftLog/watch-workout-journal.json"))) {
        self.journal = journal
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
        do {
            if let restored = try journal.load() {
                reconciler = restored
                publishProjection()
                hasReceivedContext = true
            }
        } catch {
            // Preserve an unreadable journal; replacing it could lose unacknowledged work.
            journalIsReadable = false
            Self.logger.error("Watch recovery failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn’t restore queued changes. Reopen Lift Log to retry, and review your workout on iPhone."
        }
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
            _ = try WatchWorkoutTransport.encode(request: request)
            var updated = reconciler
            updated.enqueue(request)
            guard commit(updated) else { return false }
            if isFixture {
                #if DEBUG
                applyFixtureAction(request)
                #endif
            }
            refreshConnection()
            return true
        } catch {
            Self.logger.error("Watch action encoding failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn’t send this change. Try again."
            return false
        }
    }

    private func recoverPendingTransfers() {
        guard !isFixture, journalIsReadable, hasActivatedSession,
              let session, session.activationState == .activated else { return }
        var outstandingIDs: Set<UUID> = []
        for transfer in session.outstandingUserInfoTransfers {
            do { outstandingIDs.insert(try WatchWorkoutTransport.decodeRequest(from: transfer.userInfo).operationID) }
            catch { Self.logger.error("Queued Watch request could not be read: \(error.localizedDescription, privacy: .public)") }
        }
        var updated = reconciler
        do {
            try updated.transferPending(outstandingOperationIDs: outstandingIDs, transfer: { request in
                session.transferUserInfo(try WatchWorkoutTransport.encode(request: request))
            }, checkpoint: { try journal.save($0) })
        } catch {
            // Retain the last successful checkpoint. The next refresh recognizes any
            // transfer queued before this failed save, then retries its checkpoint.
            Self.logger.error("Watch transfer recovery failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn’t queue saved changes. Reopen Lift Log to retry syncing to iPhone."
        }
        reconciler = updated
        publishProjection()
    }

    /// Persist before publishing or transferring, so a process exit cannot roll edits back.
    private func commit(_ updated: WatchWorkoutReconciler) -> Bool {
        guard journalIsReadable else {
            errorMessage = "Queued changes couldn’t be restored. Reopen Lift Log to retry."
            return false
        }
        do {
            if !isFixture { try journal.save(updated) }
            reconciler = updated
            publishProjection()
            return true
        } catch {
            Self.logger.error("Watch recovery save failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn’t save queued changes on this Watch. Free some space and try again."
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
        await alerts.synchronize(state: alertState, isReachable: isReachable,
                                 phoneHasCurrentRest: phoneHasCurrentRest)
    }

    var phoneHasCurrentRest: Bool { alertState.hasSameRest(as: reconciler.baseState) }

    func refreshConnection() {
        hasPendingActions = !reconciler.pending.isEmpty || !(session?.outstandingUserInfoTransfers.isEmpty ?? true)
        guard let session else { return }
        isReachable = session.isReachable
        isConnected = session.activationState == .activated
        recoverPendingTransfers()
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
        var updated = reconciler
        guard updated.accept(incoming), commit(updated) else { return }
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
        let cached: WatchWorkoutState?
        do {
            cached = session.receivedApplicationContext.isEmpty ? nil
                : try WatchWorkoutTransport.decodeState(from: session.receivedApplicationContext)
        } catch {
            cached = nil
            Self.logger.error("Cached Watch snapshot rejected: \(error.localizedDescription, privacy: .public)")
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Retire cached acknowledgements before deciding which saved operations
            // need transfer recovery. Do not race two independently scheduled tasks.
            if let cached { self.accept(cached) }
            self.hasActivatedSession = activationState == .activated
            self.refreshConnection()
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
            var updated = self.reconciler
            if failed, let operationID, updated.fail(operationID: operationID) {
                _ = self.commit(updated)
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
