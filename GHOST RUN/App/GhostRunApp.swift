import SwiftUI

@main
struct GhostRunApp: App {
    var body: some Scene {
        WindowGroup {
            GameRootView()
                .preferredColorScheme(.dark)
        }
    }
}
