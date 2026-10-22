import Observation
import OSLog
import WatchConnectivity

/// The phone owns the workout. Connectivity failures never interfere with local saves.
@Observable @MainActor
final class WatchWorkoutService: NSObject, WCSessionDelegate {
    @ObservationIgnored private let store: WorkoutStore
    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private var lastState: WatchWorkoutState?
    nonisolated private static let logger = Logger(subsystem: "com.liftlog.app", category: "WatchWorkoutService")

    init(store: WorkoutStore) {
        self.store = store
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    func synchronize() {
        synchronize(force: false)
    }

    private func synchronize(force: Bool) {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        let state = store.watchWorkoutState
        guard force || state != lastState else { return }
        do {
            let dictionary = try WatchWorkoutTransport.encode(state: state)
            try session.updateApplicationContext(dictionary)
            lastState = state
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

    nonisolated private func receive(_ dictionary: [String: Any]) {
        do {
            // Decode before the actor hop; only the Sendable action crosses the boundary.
            let action = try WatchWorkoutTransport.decodeAction(from: dictionary)
            Task { @MainActor [weak self] in
                guard let self else { return }
                store.applyWatchAction(action)
                // Rejected/stale actions also get an authoritative state, even if unchanged.
                synchronize(force: true)
            }
        } catch {
            Self.logger.error("Watch action could not be decoded: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receive(userInfo)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error {
            Self.logger.error("Watch activation failed: \(error.localizedDescription, privacy: .public)")
        }
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
