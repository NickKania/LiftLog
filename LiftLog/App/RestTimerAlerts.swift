import AudioToolbox
import Observation
import UserNotifications

/// Owned by the app, so hiding the workout does not stop its alert.
@Observable @MainActor
final class RestTimerAlerts: NSObject, UNUserNotificationCenterDelegate {
    private(set) var backgroundSoundUnavailable = false
    @ObservationIgnored private var timer: WorkoutRestTimer?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?
    @ObservationIgnored private var alertedID: UUID?
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var notificationsAllowed = false
    @ObservationIgnored private var checkingDelivery = false
    private static func notificationID(_ id: UUID) -> String { "workout-rest.\(id.uuidString)" }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    func synchronize(_ rest: WorkoutRestTimer?) {
        guard timer != rest else { return }
        let previous = timer
        timer = rest
        tickTask?.cancel()
        notificationTask?.cancel()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [previous, rest].compactMap { $0.map { Self.notificationID($0.id) } })
        center.removeDeliveredNotifications(withIdentifiers: [previous, rest].compactMap { $0.map { Self.notificationID($0.id) } })
        guard let rest else { return }
        // An expired countdown restored at launch shows Ready without replaying its alert.
        guard rest.endsAt > Date() else { alertedID = rest.id; return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.timer?.id == rest.id else { return }
                if rest.endsAt <= Date() {
                    if self.isActive && !self.checkingDelivery { self.playTone(for: rest.id) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        notificationTask = Task { [weak self] in
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            }
            guard let self, !Task.isCancelled, self.timer?.id == rest.id else { return }
            self.notificationsAllowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            self.backgroundSoundUnavailable = !self.notificationsAllowed || settings.authorizationStatus == .provisional || settings.soundSetting != .enabled
            guard self.notificationsAllowed, rest.endsAt > Date(), self.alertedID != rest.id else { return }
            let content = UNMutableNotificationContent()
            content.title = "Rest complete"
            content.body = "Time to start your next set."
            content.sound = .default
            content.userInfo = ["timerID": rest.id.uuidString]
            let request = UNNotificationRequest(identifier: Self.notificationID(rest.id), content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, rest.endsAt.timeIntervalSinceNow), repeats: false))
            try? await center.add(request)
            // A cancellation during add must not leave a stale alert behind.
            if self.timer?.id != rest.id { center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID(rest.id)]) }
        }
    }

    func setActive(_ active: Bool) {
        let wasActive = isActive
        isActive = active
        guard active, !wasActive, let timer, timer.endsAt <= Date() else { return }
        // Authorization alone does not prove delivery (permission prompts and delayed alerts
        // can cross the deadline). Check delivery before deciding whether to replay a tone.
        checkingDelivery = true
        Task { [weak self] in
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            guard let self else { return }
            self.checkingDelivery = false
            guard self.isActive, self.timer?.id == timer.id else { return }
            if !self.backgroundSoundUnavailable,
               delivered.contains(where: { $0.request.identifier == Self.notificationID(timer.id) }) {
                self.alertedID = timer.id
            } else {
                self.playTone(for: timer.id)
            }
        }
    }

    private func playTone(for id: UUID) {
        guard timer?.id == id, alertedID != id else { return }
        alertedID = id
        AudioServicesPlayAlertSound(1005)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = (notification.request.content.userInfo["timerID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor [weak self] in
            guard let self, let id, self.timer?.id == id else { completionHandler([]); return }
            if self.isActive {
                self.playTone(for: id)
                completionHandler([])
            } else {
                if !self.backgroundSoundUnavailable { self.alertedID = id }
                completionHandler([.banner, .list, .sound])
            }
        }
    }
}
