import SwiftUI

@main
struct LiftLogApp: App {
    @State private var store: WorkoutStore

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiftLogUITests.json")
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
        }
    }
}
