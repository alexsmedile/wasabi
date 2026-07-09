import SwiftUI

@main
struct WasabiApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 760)
    }
}
