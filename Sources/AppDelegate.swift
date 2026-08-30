import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var mainController: MainViewController!
    private var launchFlowCompleted = false
    private var proOfferTimer: Timer?
    private var trialExpiryTimer: Timer?

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

        // Lowest-friction first run: start the 7-day Pro trial automatically and
        // open the app. No account, card, or onboarding decision is required.
        LicenseManager.shared.startTrial()
        finishLaunching()
    }

    private func finishLaunching() {
        guard !launchFlowCompleted else { return }
        launchFlowCompleted = true
        if LicenseManager.shared.isActivated {
            LicenseManager.shared.revalidateInBackground()
        }
        showMainWindow()
        scheduleAutomaticProOffer()
        scheduleTrialExpiryNotice()
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

    func applicationDidBecomeActive(_ notification: Notification) {
        guard launchFlowCompleted else { return }
        scheduleAutomaticProOffer()
        scheduleTrialExpiryNotice()
    }

    /// Show Upgrade once, after 24 hours from the original trial start. If another
    /// license window is open or Wasabi is in the background, retry later instead
    /// of interrupting the user in the wrong context.
    private func scheduleAutomaticProOffer() {
        proOfferTimer?.invalidate()
        proOfferTimer = nil
        guard let delay = LicenseManager.shared.timeUntilAutomaticProOffer else { return }

        if delay <= 0 {
            guard NSApp.isActive, !LicenseWindow.isPresenting else {
                proOfferTimer = Timer.scheduledTimer(
                    timeInterval: 60,
                    target: self,
                    selector: #selector(automaticProOfferTimerFired),
                    userInfo: nil,
                    repeats: false
                )
                return
            }
            LicenseWindow(mode: .upgrade(.dayOne))
                .present(onComplete: {})
            return
        }

        proOfferTimer = Timer.scheduledTimer(
            timeInterval: delay,
            target: self,
            selector: #selector(automaticProOfferTimerFired),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func automaticProOfferTimerFired() {
        scheduleAutomaticProOffer()
    }

    /// Show one non-blocking notice when the Pro trial expires. Wasabi Free remains
    /// usable, every service/session stays persisted, and free-tier selection gates
    /// continue to enforce which services can open.
    private func scheduleTrialExpiryNotice() {
        trialExpiryTimer?.invalidate()
        trialExpiryTimer = nil
        guard let delay = LicenseManager.shared.timeUntilTrialExpiryNotice else { return }

        if delay <= 0 {
            guard NSApp.isActive, !LicenseWindow.isPresenting else {
                trialExpiryTimer = Timer.scheduledTimer(
                    timeInterval: 60,
                    target: self,
                    selector: #selector(trialExpiryTimerFired),
                    userInfo: nil,
                    repeats: false
                )
                return
            }
            let hasLockedServices = ServiceRegistry.shared.all().count > 2
            LicenseWindow(mode: .trialExpired(hasLockedServices: hasLockedServices))
                .present(onComplete: {})
            return
        }

        trialExpiryTimer = Timer.scheduledTimer(
            timeInterval: delay,
            target: self,
            selector: #selector(trialExpiryTimerFired),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func trialExpiryTimerFired() {
        scheduleTrialExpiryNotice()
    }

    /// App menu ▸ License… — open the license window any time. `forMenu` shows the
    /// activated-status panel when already Pro, otherwise the compact Upgrade offer.
    @objc func showLicenseWindow() {
        LicenseWindow.forMenu().present(onComplete: {})
    }

    /// Relabel the License menu item to live status (Pro ✓ / Trial: N days / Activate)
    /// each time the app menu opens, so "am I activated?" is answerable at a glance.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: MainMenu.licenseItemTag)?.title = LicenseManager.shared.menuStatusLabel
    }
}
