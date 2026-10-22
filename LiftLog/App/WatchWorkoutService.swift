import Observation
import OSLog
import WatchConnectivity

/// The phone owns the workout. Connectivity failures never interfere with local saves.
@Observable @MainActor
final class WatchWorkoutService: NSObject, WCSessionDelegate {
    @ObservationIgnored private let store: WorkoutStore
    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private var lastState: WatchWorkoutState?
    @ObservationIgnored private let phoneSessionID = UUID()
    @ObservationIgnored private var publicationSequence: UInt64 = 0
    @ObservationIgnored private var receipt: WatchActionReceipt
    @ObservationIgnored private var recentOperationIDs: [UUID] = []
    @ObservationIgnored private var processedOperationIDs: Set<UUID> = []
    @ObservationIgnored private let defaults: UserDefaults
    private static let receiptKey = "watchWorkoutReceipt.v2"
    nonisolated private static let logger = Logger(subsystem: "com.liftlog.app", category: "WatchWorkoutService")

    init(store: WorkoutStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        var loaded = WatchActionReceipt()
        if let data = defaults.data(forKey: Self.receiptKey) {
            do { loaded = try JSONDecoder().decode(WatchActionReceipt.self, from: data) }
            catch { Self.logger.error("Watch receipt could not be loaded: \(error.localizedDescription, privacy: .public)") }
        }
        receipt = loaded
        super.init()
        // Seed the bounded dedupe window with the durable receipts after relaunch.
        for id in [loaded.lastTerminalResult?.operationID, loaded.processedThroughOperationID].compactMap({ $0 }) {
            remember(id)
        }
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    func synchronize() { synchronize(force: false) }

    private func synchronize(force: Bool) {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        let base = store.watchWorkoutState
        guard force || base != lastState else { return }
        publicationSequence += 1
        var state = base
        state.phoneSessionID = phoneSessionID
        state.publicationSequence = publicationSequence
        state.processedThroughOperationID = receipt.processedThroughOperationID
        state.lastTerminalResult = receipt.lastTerminalResult
        do {
            let dictionary = try WatchWorkoutTransport.encode(state: state)
            try session.updateApplicationContext(dictionary)
            lastState = base
            if session.isReachable {
                session.sendMessage(dictionary, replyHandler: nil) { error in
                    // Application context still delivers the latest state when reachable again.
                    Self.logger.error("Watch message failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            Self.logger.error("Watch synchronization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func remember(_ id: UUID) {
        guard processedOperationIDs.insert(id).inserted else { return }
        recentOperationIDs.append(id)
        if recentOperationIDs.count > 128 { processedOperationIDs.remove(recentOperationIDs.removeFirst()) }
    }

    private func process(_ request: WatchActionRequest) {
        guard !processedOperationIDs.contains(request.operationID) else {
            synchronize(force: true)
            return
        }
        let succeeded = store.applyWatchAction(request.action)
        receipt.record(request, succeeded: succeeded)
        remember(request.operationID)
        do { defaults.set(try JSONEncoder().encode(receipt), forKey: Self.receiptKey) }
        catch { Self.logger.error("Watch receipt could not be saved: \(error.localizedDescription, privacy: .public)") }
        // Success and rejection both acknowledge the request, even without a store revision.
        synchronize(force: true)
    }

    nonisolated private func receive(_ dictionary: [String: Any]) {
        do {
            let request = try WatchWorkoutTransport.decodeRequest(from: dictionary)
            // WCSession delivers on its serial delegate queue. Enqueue synchronously onto
            // main's FIFO, rather than spawning independently scheduled actor tasks.
            DispatchQueue.main.async { [weak self] in self?.process(request) }
        } catch {
            Self.logger.error("Watch action could not be decoded: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { receive(message) }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { receive(userInfo) }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error { Self.logger.error("Watch activation failed: \(error.localizedDescription, privacy: .public)") }
        Task { @MainActor [weak self] in self?.synchronize(force: true) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.synchronize(force: true) }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.synchronize(force: true) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        // Wait for deactivation before activating the newly selected paired Watch.
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.lastState = nil
            self?.session?.activate()
        }
    }
}
