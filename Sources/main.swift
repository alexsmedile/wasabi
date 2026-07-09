import AppKit

// Pure-AppKit entry point (no SwiftUI) so the app builds with Command Line Tools
// only — no full Xcode, no macOS 26 required. The SwiftUI shell is parked in
// Sources/_swiftui_deferred/ for a later GUI pass; the backend
// (Service / SleepPolicy / UserAgent / WebViewController) is shared verbatim.

// The process entry point is already the main thread; assert that to the compiler
// so main-actor-isolated types (AppDelegate) can be constructed here under Swift 6.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let delegate = AppDelegate()
    app.delegate = delegate

    app.run()
}
