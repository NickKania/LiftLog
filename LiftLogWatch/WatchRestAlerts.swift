import Foundation
import OSLog
import UserNotifications

@MainActor
final class WatchRestAlerts {
    private let center = UNUserNotificationCenter.current()
    private var requestedAuthorization = false
    private var scheduledIdentifier: String?
    private var updateTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.liftlog.app.watchkitapp", category: "WatchRestAlerts")

    func synchronize(state: WatchWorkoutState, isReachable: Bool) async {
        let previous = updateTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            // Serialize notification-center writes so a cancelled old deadline cannot
            // remove or overwrite the replacement request with the same timer identity.
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.update(state: state, isReachable: isReachable)
        }
        updateTask = task
        await task.value
    }

    private func update(state: WatchWorkoutState, isReachable: Bool) async {
        // Recover requests left by an earlier process as well as this process's timer.
        let pending = await center.pendingNotificationRequests()
        guard !Task.isCancelled else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("watch-rest-") })
        if let scheduledIdentifier {
            center.removeDeliveredNotifications(withIdentifiers: [scheduledIdentifier])
            self.scheduledIdentifier = nil
        }
        // The phone supplies background alerts while reachable. The Watch schedules its
        // own only while unreachable (for example, when the phone is in a locker).
        guard !isReachable else { return }
        if !requestedAuthorization {
            requestedAuthorization = true
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { Self.logger.error("Rest alert permission failed: \(error.localizedDescription, privacy: .public)") }
        }
        guard !Task.isCancelled else { return }
        guard let workout = state.active, let id = workout.restTimerID, let endsAt = workout.restEndsAt,
              endsAt > Date() else { return }
        let identifier = "watch-rest-\(id.uuidString)"
        scheduledIdentifier = identifier
        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = WatchPresentation.nextPrescription(workout, unit: state.unitRaw)
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, endsAt.timeIntervalSinceNow), repeats: false)
        do { try await center.add(.init(identifier: identifier, content: content, trigger: trigger)) }
        catch { Self.logger.error("Rest alert scheduling failed: \(error.localizedDescription, privacy: .public)") }
        // A subsequent serialized update removes/replaces this request. Leaving it scheduled
        // when the screen disappears is deliberate: rest must still alert in the background.
    }
}
