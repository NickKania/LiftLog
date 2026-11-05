import UIKit

/// iOS grants finite time to finish an already-started ChatGPT response after
/// backgrounding. This is not a persistent connection or a background transfer.
@MainActor
final class AssistantRequestActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private let onExpiration: @MainActor () -> Void
    private let end: @MainActor (UIBackgroundTaskIdentifier) -> Void

    init(onExpiration: @escaping @MainActor () -> Void,
         end: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }) {
        self.onExpiration = onExpiration
        self.end = end
    }

    static func begin(onExpiration: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let activity = AssistantRequestActivity(onExpiration: onExpiration)
        activity.start()
        return { activity.finish() }
    }

    func start(begin: @MainActor (@escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier = { expiration in
        // UIKit invokes this handler on the main actor. End the assertion before
        // returning rather than scheduling cleanup behind another task.
        UIApplication.shared.beginBackgroundTask(withName: "Assistant response") {
            expiration()
        }
    }) {
        guard identifier == .invalid else { return }
        identifier = begin { [weak self] in self?.expire() }
    }

    func finish() {
        guard identifier != .invalid else { return }
        let previous = identifier
        identifier = .invalid
        end(previous)
    }

    private func expire() {
        guard identifier != .invalid else { return }
        onExpiration()
        finish()
    }
}
