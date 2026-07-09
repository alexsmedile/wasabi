import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var mainController: MainViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install the main menu so ⌘C/⌘V/⌘X/⌘A reach the focused WebView via the
        // responder chain. Without it those shortcuts are swallowed — see MainMenu.
        NSApp.mainMenu = MainMenu.build()

        if ProcessInfo.processInfo.environment["WASABI_LICENSE_SELFCHECK"] == "1" {
            LicenseManager.selfCheck()
        }
        if ProcessInfo.processInfo.environment["WASABI_UPDATE_SELFCHECK"] == "1" {
            UpdateChecker.selfCheck()
        }

        // Freemium: the app ALWAYS opens (no launch wall). Entitlement is enforced
        // at the feature gates via LicenseManager.isUnlocked(_:), not here. First
        // launch stamps the local trial; a stored key re-checks in the background
        // (grace window carries offline users). LicenseWindow is now a menu-reachable
        // "Activate / Upgrade" entry point, not a launch gate. To test Pro/free
        // gating in a dev build, set WASABI_DEV_FORCE_TIER=pro|trial|free.
        LicenseManager.shared.startTrialIfFirstLaunch()
        if LicenseManager.shared.isActivated {
            LicenseManager.shared.revalidateInBackground()
        }
        showMainWindow()
    }

    private func showMainWindow() {
        mainController = MainViewController()

        let defaultSize = MainViewController.defaultWindowSize
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wasabi"
        window.contentViewController = mainController
        window.setFrameAutosaveName("WasabiMainWindow")
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        // Non-blocking: silent unless a newer version is advertised (and a real
        // update host is configured). Runs after the app UI is up.
        UpdateChecker.checkInBackground()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// App menu ▸ License… — open the activation window any time. `forMenu` shows the
    /// activated-status panel when already Pro, else the key field. LicenseWindow
    /// self-retains; on activation the tier flips to `.pro` and gates lift next check.
    @objc func showLicenseWindow() {
        LicenseWindow.forMenu().present(onActivated: {})
    }

    /// Relabel the License menu item to live status (Pro ✓ / Trial: N days / Activate)
    /// each time the app menu opens, so "am I activated?" is answerable at a glance.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: MainMenu.licenseItemTag)?.title = LicenseManager.shared.menuStatusLabel
    }
}
