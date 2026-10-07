import SwiftUI

@main
struct LiftLogApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: WorkoutStore
    @State private var restAlerts = RestTimerAlerts()
    @State private var liveActivity = WorkoutLiveActivity()
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
        accountStore.onConnectionChange = { [weak workoutAssistant] in workoutAssistant?.accountWillChange() }
        _assistant = State(initialValue: workoutAssistant)
    }

    private static func makeAssistant(store: WorkoutStore, accounts: ChatGPTAccountStore) -> WorkoutAssistant {
        WorkoutAssistant(store: store, accessToken: {
            try await accounts.accessToken()
        }, accountIdentity: {
            "\(accounts.currentAccount?.id ?? "none"):\(accounts.revision):\(accounts.canUsePlan)"
        }, storageURL: assistantStorageURL,
        archiveAccountIdentity: { accounts.currentAccount?.id })
    }

    private static var assistantStorageURL: URL {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiftLogAssistantUITests.json")
            if ProcessInfo.processInfo.arguments.contains("--reset-ui-testing") {
                try? FileManager.default.removeItem(at: url)
            }
            return url
        }
        #endif
        return WorkoutAssistant.defaultStorageURL
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(chatGPT)
                .environment(assistant)
                .environment(restAlerts)
                .tint(.blue)
                .task {
                    restAlerts.setActive(scenePhase == .active)
                    restAlerts.synchronize(store.activeWorkout?.restTimer)
                    liveActivity.synchronize(store.activeWorkout?.activitySnapshot, isActive: scenePhase == .active)
                    store.cloudBackup.scheduleBackup()
                }
                .onChange(of: store.activeWorkout?.restTimer) { _, rest in restAlerts.synchronize(rest) }
                .onChange(of: store.activeWorkout?.activitySnapshot) { _, snapshot in
                    liveActivity.synchronize(snapshot, isActive: scenePhase == .active)
                }
                .onChange(of: scenePhase) { _, phase in
                    restAlerts.setActive(phase == .active)
                    liveActivity.synchronize(store.activeWorkout?.activitySnapshot, isActive: phase == .active)
                    if phase == .active { store.cloudBackup.scheduleBackup() }
                    else if phase == .background {
                        assistant.saveChats()
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
