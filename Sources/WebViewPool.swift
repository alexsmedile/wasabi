import AppKit

/// Owns the sleep/wake lifecycle for every service's WebViewController.
///
/// One service is `active` at a time (mounted, always kept live). The rest are
/// governed by their per-service `SleepPolicy`:
///   • keepRunning    — never slept.
///   • autoSleepTimer — slept after N seconds of inactivity.
///   • smartSleep     — slept, then periodically woken to sync + badge, sleeping
///                      again between cycles on an adaptive interval.
///
/// The pool reclaims memory by calling `WebViewController.sleep()` (releases the
/// WebContent process) and restores via `wake()` (reloads from the persistent
/// data store — no re-login).
@MainActor
final class WebViewPool {
    private var controllers: [String: WebViewController]
    private var policies: [String: SleepPolicy] = [:]
    private var activeID: String = ""

    /// Per-service timers. For autoSleepTimer this is the idle→sleep timer;
    /// for smartSleep it is the next wake-cycle timer.
    private var timers: [String: Timer] = [:]
    /// When each service last stopped being active (for smart-sleep backoff).
    private var lastActive: [String: Date] = [:]
    /// Consecutive failed background loads. Successful loads reset the count;
    /// failures exponentially back off the next wake (capped at one hour).
    private var smartWakeFailures: [String: Int] = [:]
    /// Generation tokens make late navigation callbacks and timers harmless.
    private var smartWakeGeneration: [String: Int] = [:]
    /// Services currently inside an offscreen load or post-load sync window.
    private var backgroundWakeActive: Set<String> = []

    /// Fired after any service sleeps or wakes (active switch, timer teardown, or
    /// smart-wake cycle) so the UI can repaint per-service state (the status dot).
    var onLiveStateChanged: (() -> Void)?

    private static let defaultsKeyPrefix = "wasabi.sleeppolicy."

    init(controllers: [String: WebViewController]) {
        // Run the one-time Smart-Sleep migration before seeding policies, so the
        // pool reads the migrated values rather than the pre-migration store.
        Self.migrateToSmartDefaultIfNeeded()
        self.controllers = controllers
        for id in controllers.keys {
            // Unknown id (every new service) defaults to Smart Sleep — the lever
            // toward the <500 MB goal. A stored pick always wins (remember-last).
            policies[id] = Self.loadPolicy(id: id) ?? controllers[id]?.service.sleepPolicy ?? .smartSleep
        }
        observeAppFocus()
    }

    // MARK: - App focus (drives the smart-sleep grace window)

    /// Smart-sleep uses a longer grace while Wasabi is frontmost (you're still in
    /// the app, may flip back to reply) and a short one once you leave for another
    /// app. Track the app's active state so `schedule` can pick the right grace.
    private var appIsActive = NSApp.isActive

    private func observeAppFocus() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appIsActive = false
                self.pauseBackgroundSmartWakes()
            }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appIsActive = true
                self.resumeBackgroundSmartWakes()
            }
        }
    }

    /// The grace to use right now for a just-left smart-sleep service.
    private var grace: TimeInterval {
        appIsActive ? SmartSleepSchedule.graceForeground : SmartSleepSchedule.graceBackground
    }

    /// On app-resign, stop offscreen network/render work. A service still in its
    /// pre-teardown grace gets the shorter background grace; an active Smart-Sleep
    /// wake is torn down immediately; already-slept services remain asleep.
    private func pauseBackgroundSmartWakes() {
        var liveStateChanged = false
        for id in controllers.keys where id != activeID && policy(for: id) == .smartSleep {
            if backgroundWakeActive.contains(id) {
                cancelSmartWake(id)
                if controllers[id]?.isAwake == true {
                    controllers[id]?.sleep()
                    liveStateChanged = true
                }
            } else if controllers[id]?.isAwake == true {
                // A service still in its foreground grace gets the shorter
                // background grace. A completed background wake is handled above.
                schedule(id)
            } else {
                cancelTimer(id) // no periodic full-page wakes while app is inactive
            }
        }
        if liveStateChanged { onLiveStateChanged?() }
    }

    private func resumeBackgroundSmartWakes() {
        for id in controllers.keys where id != activeID && policy(for: id) == .smartSleep {
            if controllers[id]?.isAwake == false { scheduleSmartWake(id) }
        }
    }

    // MARK: - Policy access

    func policy(for id: String) -> SleepPolicy {
        let stored = policies[id] ?? .smartSleep
        // Gate 4: Smart Sleep is Pro. Clamp at READ time (not persisted) so a stored
        // .smartSleep pick survives a lapse/upgrade and resumes untouched — a free
        // user just gets the plain 5-min timer meanwhile. Every timer/menu read routes
        // through here, so one clamp covers scheduling + the right-click checkmark.
        if stored == .smartSleep, !LicenseManager.shared.isUnlocked(.smartSleep) {
            return .sleepAfterDefault
        }
        return stored
    }

    /// Change a service's policy, persist it, and re-evaluate its timers now.
    func setPolicy(_ policy: SleepPolicy, for id: String) {
        cancelSmartWake(id)
        smartWakeFailures[id] = 0
        policies[id] = policy
        Self.savePolicy(policy, id: id)
        // Re-arm scheduling for this service unless it's the active one.
        if id != activeID { schedule(id) }
        else { cancelTimer(id) }
    }

    // MARK: - Activation

    /// Mark `id` as the active (mounted) service. Wakes it, and re-schedules the
    /// service being left according to its policy.
    func setActive(_ id: String) {
        let previous = activeID
        activeID = id
        lastActive[id] = Date()
        smartWakeFailures[id] = 0       // manual activation resets the breaker
        cancelTimer(id)                 // active service is never auto-slept
        cancelSmartWake(id)

        if !previous.isEmpty, previous != id {
            lastActive[previous] = Date()
            schedule(previous)          // start the leaving service's policy clock
        }
    }

    /// Sleep a service right now, regardless of its policy or timers — the
    /// "Sleep now" menu action. No-op for the active service (always kept live) or
    /// one already asleep. Cancels any pending timer so the manual sleep sticks
    /// until the next activation; smartSleep's wake cycle re-arms on next select.
    func sleepNow(_ id: String) {
        guard id != activeID, controllers[id]?.isAwake == true else { return }
        cancelTimer(id)
        cancelSmartWake(id)
        controllers[id]?.sleep()
        onLiveStateChanged?()
    }

    // MARK: - Scheduling

    /// Arm the appropriate timer for an inactive service per its policy.
    private func schedule(_ id: String) {
        cancelTimer(id)
        switch policy(for: id) {
        case .keepRunning:
            break                       // stays live; nothing to do
        case .autoSleepTimer(let timeout):
            armTimer(id, after: timeout) { [weak self] in
                self?.controllers[id]?.sleep()
                self?.onLiveStateChanged?()
            }
        case .smartSleep:
            // Don't tear down the instant you switch away — that makes flicking
            // between services pay a full teardown + cold reload every time. Stay
            // live for a short grace window; switching back cancels this timer
            // (via setActive → cancelTimer) so no teardown happens. Once the grace
            // elapses, sleep and begin the adaptive wake cycle.
            armTimer(id, after: grace) { [weak self] in
                guard let self, id != self.activeID else { return }
                self.controllers[id]?.sleep()
                self.onLiveStateChanged?()
                self.scheduleSmartWake(id)
            }
        }
    }

    /// Smart-sleep: schedule the next background wake based on idle time.
    private func scheduleSmartWake(_ id: String) {
        guard appIsActive else {
            cancelTimer(id)
            return
        }
        let idle = Date().timeIntervalSince(lastActive[id] ?? Date())
        let failures = smartWakeFailures[id] ?? 0
        guard failures < SmartSleepSchedule.maxConsecutiveFailures else {
            cancelTimer(id)             // circuit open until selection/policy change
            return
        }
        let interval = SmartSleepSchedule.wakeInterval(
            idleFor: idle,
            consecutiveFailures: failures
        )
        armTimer(id, after: interval) { [weak self] in
            guard let self, self.appIsActive, id != self.activeID else { return }
            self.smartWakeCycle(id)
        }
    }

    /// One smart-sleep cycle: wake (offscreen) to sync + refresh badge, then
    /// sleep again and schedule the next, longer cycle.
    private func smartWakeCycle(_ id: String) {
        guard appIsActive, let controller = controllers[id], id != activeID else { return }
        let generation = nextSmartWakeGeneration(id)
        backgroundWakeActive.insert(id)
        controller.observeBackgroundLoad { [weak self] success in
            self?.backgroundLoadFinished(id, generation: generation, success: success)
        }
        controller.wake()              // rebuilds + reloads from persistent store
        onLiveStateChanged?()
        armTimer(id, after: SmartSleepSchedule.loadTimeout) { [weak self] in
            self?.backgroundLoadFinished(id, generation: generation, success: false)
        }
    }

    private func backgroundLoadFinished(_ id: String, generation: Int, success: Bool) {
        guard smartWakeGeneration[id] == generation,
              backgroundWakeActive.contains(id),
              id != activeID else { return }
        controllers[id]?.cancelBackgroundLoadObservation()

        if success && appIsActive {
            smartWakeFailures[id] = 0
            armTimer(id, after: SmartSleepSchedule.syncWindow) { [weak self] in
                self?.finishSmartWake(id, generation: generation)
            }
        } else {
            smartWakeFailures[id, default: 0] += 1
            finishSmartWake(id, generation: generation)
        }
    }

    private func finishSmartWake(_ id: String, generation: Int) {
        guard smartWakeGeneration[id] == generation,
              backgroundWakeActive.remove(id) != nil,
              id != activeID else { return }
        controllers[id]?.sleep()
        onLiveStateChanged?()
        scheduleSmartWake(id)
    }

    @discardableResult
    private func nextSmartWakeGeneration(_ id: String) -> Int {
        let next = (smartWakeGeneration[id] ?? 0) &+ 1
        smartWakeGeneration[id] = next
        return next
    }

    private func cancelSmartWake(_ id: String) {
        cancelTimer(id)
        _ = nextSmartWakeGeneration(id)
        backgroundWakeActive.remove(id)
        controllers[id]?.cancelBackgroundLoadObservation()
    }

    // MARK: - Timer helpers

    private func armTimer(
        _ id: String,
        after seconds: TimeInterval,
        _ block: @escaping @MainActor @Sendable () -> Void
    ) {
        cancelTimer(id)
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                block()
            }
        }
        timers[id] = timer
    }

    private func cancelTimer(_ id: String) {
        timers[id]?.invalidate()
        timers[id] = nil
    }

    // MARK: - Grow / shrink (add & remove services at runtime)

    /// Register a newly-added service's controller and seed its policy (a stored
    /// pick wins; otherwise the given default). No scheduling here — the caller
    /// selects the new service right after, and `setActive` drives its lifecycle.
    func addController(_ controller: WebViewController, policy: SleepPolicy = .smartSleep) {
        let id = controller.service.id
        controllers[id] = controller
        policies[id] = Self.loadPolicy(id: id) ?? policy
    }

    /// Drop a removed service's controller from the pool. Cancels its timer and
    /// forgets its policy; deleting the data store / clearing the policy key is the
    /// caller's responsibility (see MainViewController remove path).
    func removeController(id: String) {
        cancelTimer(id)
        cancelSmartWake(id)
        controllers[id] = nil
        policies[id] = nil
        lastActive[id] = nil
        smartWakeFailures[id] = nil
        smartWakeGeneration[id] = nil
    }

    // MARK: - UserDefaults

    private static func key(_ id: String) -> String { defaultsKeyPrefix + id }

    private static func loadPolicy(id: String) -> SleepPolicy? {
        guard let raw = UserDefaults.standard.string(forKey: key(id)) else { return nil }
        return SleepPolicy(rawString: raw)
    }

    private static func savePolicy(_ policy: SleepPolicy, id: String) {
        UserDefaults.standard.set(policy.rawString, forKey: key(id))
    }

    // MARK: - One-time Smart-Sleep migration

    private static let smartDefaultMigrationKey = "wasabi.migrated.smartdefault.v1"

    /// The original built-ins shipped as `.keepRunning`. Smart Sleep is now the
    /// default everywhere, so on first launch after this change we reset the
    /// seeded built-ins' *stored* policy to `.smartSleep` — once. The flag guards
    /// re-runs, so every later pick the user makes via the right-click menu is
    /// remembered and never re-clobbered ("reset everyone once, then honor me").
    private static func migrateToSmartDefaultIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: smartDefaultMigrationKey) else { return }
        for id in ["whatsapp", "telegram"] {
            // Only rewrite a service that actually has a stored policy (i.e. an
            // existing install). A fresh install has none and gets Smart from the
            // fallback — nothing to migrate.
            if defaults.string(forKey: key(id)) != nil {
                savePolicy(.smartSleep, id: id)
            }
        }
        defaults.set(true, forKey: smartDefaultMigrationKey)
    }
}
