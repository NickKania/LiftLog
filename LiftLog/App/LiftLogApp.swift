import SwiftUI

@main
struct LiftLogApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: WorkoutStore
    @State private var backgroundBackup = BackupBackgroundActivity()

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiftLogUITests.sqlite")
            if ProcessInfo.processInfo.arguments.contains("--reset-ui-testing") {
                try? FileManager.default.removeItem(at: url)
            }
            _store = State(initialValue: WorkoutStore(fileURL: url))
        } else {
            _store = State(initialValue: WorkoutStore())
        }
        #else
        _store = State(initialValue: WorkoutStore())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.blue)
                .task { store.cloudBackup.scheduleBackup() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.cloudBackup.scheduleBackup() }
                    else if phase == .background {
                        backgroundBackup.run(store.cloudBackup)
                    }
                }
        }
    }
}

/// Give a pending snapshot time to finish when the app leaves the foreground.
@MainActor
private final class BackupBackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func run(_ backup: CloudBackupManager) {
        guard backup.automaticBackupsEnabled, identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Workout backup") { [weak self] in
            Task { @MainActor in self?.finish() }
        }
        let currentIdentifier = identifier
        Task {
            await backup.backUpIfEnabled()
            finish(expected: currentIdentifier)
        }
    }

    private func finish(expected: UIBackgroundTaskIdentifier? = nil) {
        guard identifier != .invalid, expected == nil || expected == identifier else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
