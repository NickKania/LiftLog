import SwiftUI

@main
struct LiftLogWatchApp: App {
    @State private var client = WatchSessionClient()

    var body: some Scene {
        WindowGroup {
            WatchRootView(client: client)
                .preferredColorScheme(.dark)
                .tint(.green)
        }
    }
}
