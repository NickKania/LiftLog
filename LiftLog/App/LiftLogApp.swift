import SwiftUI

@main
struct LiftLogApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: WorkoutStore
    @State private var backgroundBackup = BackupBackgroundActivity()
    @State private var chatGPT: ChatGPTAccountStore
    @State private var assistant: WorkoutAssistant

    init() {
        let workoutStore: WorkoutStore
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiftLogUITests.sqlite")
            if ProcessInfo.processInfo.arguments.contains("--reset-ui-testing") {
                try? FileManager.default.removeItem(at: url)
            }
            workoutStore = WorkoutStore(fileURL: url)
        } else {
            workoutStore = WorkoutStore()
        }
        #else
        workoutStore = WorkoutStore()
        #endif
        let accountStore: ChatGPTAccountStore
        #if DEBUG
        accountStore = AssistantUITestFixture.isEnabled ? AssistantUITestFixture.makeAccounts() : ChatGPTAccountStore()
        #else
        accountStore = ChatGPTAccountStore()
        #endif
        _store = State(initialValue: workoutStore)
        _chatGPT = State(initialValue: accountStore)
        let workoutAssistant: WorkoutAssistant
        #if DEBUG
        if AssistantUITestFixture.isEnabled {
            workoutAssistant = AssistantUITestFixture.makeAssistant(store: workoutStore)
        } else {
            workoutAssistant = Self.makeAssistant(store: workoutStore, accounts: accountStore)
        }
        #else
        workoutAssistant = Self.makeAssistant(store: workoutStore, accounts: accountStore)
        #endif
        accountStore.onConnectionChange = { [weak workoutAssistant] in workoutAssistant?.reset() }
        _assistant = State(initialValue: workoutAssistant)
    }

    private static func makeAssistant(store: WorkoutStore, accounts: ChatGPTAccountStore) -> WorkoutAssistant {
        WorkoutAssistant(store: store, accessToken: {
            try await accounts.accessToken()
        }, accountIdentity: {
            "\(accounts.currentAccount?.id ?? "none"):\(accounts.revision):\(accounts.canUsePlan)"
        })
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(chatGPT)
                .environment(assistant)
                .tint(.blue)
                .task { store.cloudBackup.scheduleBackup() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.cloudBackup.scheduleBackup() }
                    else if phase == .background {
                        backgroundBackup.run(store.cloudBackup)
                    }
                }
                #if DEBUG
                .preferredColorScheme(AssistantUITestFixture.isEnabled && ProcessInfo.processInfo.arguments.contains("--assistant-dark-ui-fixture") ? .dark : nil)
                #endif
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
