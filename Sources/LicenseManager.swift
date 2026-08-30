import Foundation
import Security

/// A gated capability. Every feature site asks one question —
/// `LicenseManager.shared.isUnlocked(_:)` — so there's no scattered `isLicensed`
/// boolean to miss. `customIcons` is here now so the future picker links straight in.
enum Feature { case unlimitedServices, smartSleep, customIcons, reorderServices }

/// Effective entitlement. Three explicit states so the UI can show "Trial: N days
/// left" (not just locked/unlocked). `trial` and `pro` unlock everything gated.
enum Tier { case free, trial, pro }

/// Owns license state: the key lives in the Keychain (a secret, not
/// `UserDefaults`); the last-validated date + cached expiry live in
/// `UserDefaults` (not secret, and needed for offline grace).
///
/// Launch decision (`gateDecision`) is pure and covers the three cases that
/// matter: no key → block with the license window; key inside the grace window →
/// let in immediately (revalidate in the background); key past grace → let in
/// only if the last known verdict wasn't an explicit `invalid`. We never hard-
/// lock on `unreachable` — a flaky network must not lock out a paying user.
@MainActor
final class LicenseManager {
    #if WASABI_DEV
    // Dev builds use the offline stub (accepts WASABI-XXXX demo keys).
    static let shared = LicenseManager()
    #else
    // Release builds use the real Lemon Squeezy backend (see DECISIONS.md). No
    // secret ships — the license endpoints authenticate with the user's key.
    static let shared = LicenseManager(backend: LemonSqueezyBackend())
    #endif

    enum Gate: Equatable {
        case licensed          // proceed to the app
        case needsKey          // show the license window
    }

    /// How long a validated key is trusted without re-reaching the store.
    /// ponytail: 14 days is a knob, not a law — widen if users travel offline.
    static let graceDays = 14

    private static let account = "app.wasabi.license"      // Keychain account
    private static let service = "app.wasabi.Wasabi"       // Keychain service
    private static let lastValidatedKey = "wasabi.license.lastValidated"
    private static let lastVerdictInvalidKey = "wasabi.license.lastVerdictInvalid"
    private static let instanceIDKey = "wasabi.license.instanceID"   // LS device instance (not secret)
    private static let trialFirstLaunchKey = "wasabi.trial.firstLaunch"   // Date, stamped once
    private static let proOfferSeenKey = "wasabi.proOffer.seen"
    private static let trialExpiryNoticeSeenKey = "wasabi.trial.expiryNoticeSeen"

    /// Full-unlock trial length. ponytail: local Date, not DRM.
    static let trialDays = 7
    static let automaticProOfferDelay: TimeInterval = 86_400
    static let trialDuration: TimeInterval = Double(trialDays) * 86_400

    private let defaults: UserDefaults
    let backend: LicenseBackend

    #if WASABI_DEV
    // Dev builds default to the stub (accepts WASABI-XXXX demo keys). This
    // initializer is COMPILED OUT of release builds, so a shipped binary cannot
    // fall back to the stub and validate fake keys.
    init(defaults: UserDefaults = .standard, backend: LicenseBackend = StubLicenseBackend()) {
        self.defaults = defaults
        self.backend = backend
    }
    #else
    // Release builds MUST pass a real backend. There is no default: until a
    // vendor adapter (LemonSqueezyBackend/…) exists and is wired here, a release
    // build fails to compile — which is the point. It is impossible to ship a
    // paid build that silently accepts stub keys. Replace the fatalError with the
    // real backend when it lands: `init() { self.init(backend: LemonSqueezyBackend()) }`
    init(defaults: UserDefaults = .standard, backend: LicenseBackend) {
        self.defaults = defaults
        self.backend = backend
    }
    #endif

    // MARK: - Launch gate

    /// The synchronous, offline decision made at launch. Pure given its inputs so
    /// it's unit-checkable (see `LicenseManager.selfCheck`).
    ///
    /// An explicit "invalid" from the store is the ONLY thing that re-gates a
    /// machine that already has a key. Being offline/past-grace does NOT: we can't
    /// tell "expired" from "just offline for weeks", and locking out a paying user
    /// over a network gap is worse than a freeloader's extra days. Expiry, when it
    /// matters, is the backend's call — it returns `.invalid`, which
    /// `revalidateInBackground` records as `lastVerdictInvalid` for the next launch.
    static func gateDecision(hasKey: Bool, lastVerdictInvalid: Bool) -> Gate {
        guard hasKey, !lastVerdictInvalid else { return .needsKey }
        return .licensed
    }

    /// Convenience wrapper using stored state.
    func gate() -> Gate {
        Self.gateDecision(
            hasKey: storedKey() != nil,
            lastVerdictInvalid: defaults.bool(forKey: Self.lastVerdictInvalidKey)
        )
    }

    // MARK: - Entitlement (the freemium seam)

    #if WASABI_DEV
    /// Dev-only tier override. `WASABI_DEV_FORCE_TIER=pro|trial|free` forces the tier
    /// so gate correctness can be tested without an LS round-trip. Compiled out of
    /// release builds. (Replaces the old WASABI_DEV_UNLICENSED launch bypass.)
    private static var forcedTier: Tier? {
        switch ProcessInfo.processInfo.environment["WASABI_DEV_FORCE_TIER"] {
        case "pro":   return .pro
        case "trial": return .trial
        case "free":  return .free
        default:      return nil
        }
    }
    #endif

    /// Effective tier now. `pro` reuses the exact forgiving offline signal `gate()`
    /// feeds `gateDecision` (`hasKey && !lastVerdictInvalid`), so a Pro user launching
    /// offline — before `revalidateInBackground` finishes — reads `.pro`, never a
    /// transient `.free` that would flap a lock or coerce a policy. Only an explicit
    /// store `.invalid` downgrades. `trial` = inside the local window and not Pro.
    var tier: Tier {
        #if WASABI_DEV
        if let forced = Self.forcedTier { return forced }
        #endif
        let hasKey = storedKey() != nil
        let invalidated = defaults.bool(forKey: Self.lastVerdictInvalidKey)
        if hasKey && !invalidated { return .pro }
        return trialActive ? .trial : .free
    }

    /// True iff the local trial window is still open. Half-open range `[0, N days)`
    /// so a clock set back before `firstLaunch` (negative delta) reads **expired**,
    /// not "active forever" — fail closed.
    private var trialActive: Bool {
        guard let start = defaults.object(forKey: Self.trialFirstLaunchKey) as? Date else { return false }
        return Self.trialIsActive(elapsed: Date().timeIntervalSince(start))
    }

    /// Pure trial-window test (selfCheck-able). Half-open `[0, N days)` — a negative
    /// elapsed (clock set back before firstLaunch) is out of range → expired.
    static func trialIsActive(elapsed: TimeInterval) -> Bool {
        (0 ..< Double(trialDays) * 86_400).contains(elapsed)
    }

    /// Pure entitlement rule (selfCheck-able): only `.free` is locked.
    static func unlocked(tier: Tier, feature: Feature) -> Bool { tier != .free }

    /// Days left in the trial (0 if not on trial / expired). For the UI countdown.
    var trialDaysRemaining: Int {
        guard tier == .trial,
              let start = defaults.object(forKey: Self.trialFirstLaunchKey) as? Date else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        return max(0, Self.trialDays - Int(elapsed / 86_400))
    }

    /// A trial can never be restarted after its first stamp.
    var canStartTrial: Bool {
        defaults.object(forKey: Self.trialFirstLaunchKey) == nil && !isActivated
    }

    /// Start the full Pro trial once. Fresh installs call this automatically so the
    /// app opens without an onboarding decision or credit-card request.
    func startTrial() {
        guard !isActivated else { return }
        if defaults.object(forKey: Self.trialFirstLaunchKey) == nil {
            defaults.set(Date(), forKey: Self.trialFirstLaunchKey)
        }
    }

    /// Seconds until the one-time automatic Pro offer is due. `nil` means no offer:
    /// the user is licensed, has already seen it, has no trial timestamp, or the
    /// trial already expired (the expiry notice is more relevant then).
    var timeUntilAutomaticProOffer: TimeInterval? {
        guard !isActivated,
              !defaults.bool(forKey: Self.proOfferSeenKey),
              let start = defaults.object(forKey: Self.trialFirstLaunchKey) as? Date else {
            return nil
        }
        return Self.softProOfferDelay(elapsed: Date().timeIntervalSince(start))
    }

    static func proOfferDelay(elapsed: TimeInterval) -> TimeInterval {
        max(0, automaticProOfferDelay - max(0, elapsed))
    }

    static func softProOfferDelay(elapsed: TimeInterval) -> TimeInterval? {
        guard elapsed < trialDuration else { return nil }
        return proOfferDelay(elapsed: elapsed)
    }

    /// Any explicit or automatic visit to the Upgrade window satisfies the one-time
    /// day-one offer. Feature gates can still show Upgrade later when relevant.
    func markProOfferSeen() {
        defaults.set(true, forKey: Self.proOfferSeenKey)
    }

    /// Seconds until the one-time trial-expiry notice is due. It is independent
    /// from the day-one soft offer so seeing one never suppresses the other.
    var timeUntilTrialExpiryNotice: TimeInterval? {
        guard !isActivated,
              !defaults.bool(forKey: Self.trialExpiryNoticeSeenKey),
              let start = defaults.object(forKey: Self.trialFirstLaunchKey) as? Date else {
            return nil
        }
        return Self.trialExpiryNoticeDelay(elapsed: Date().timeIntervalSince(start))
    }

    static func trialExpiryNoticeDelay(elapsed: TimeInterval) -> TimeInterval {
        max(0, trialDuration - max(0, elapsed))
    }

    private var trialHasExpired: Bool {
        guard let start = defaults.object(forKey: Self.trialFirstLaunchKey) as? Date else { return false }
        return Date().timeIntervalSince(start) >= Self.trialDuration
    }

    func markTrialExpiryNoticeSeen() {
        defaults.set(true, forKey: Self.trialExpiryNoticeSeenKey)
        // If the app was not opened during the trial, prevent the older day-one
        // offer from appearing after this more relevant expiry message.
        markProOfferSeen()
    }

    /// A contextual feature-gate Upgrade opened after expiry already communicates
    /// the loss of Pro. Count it as the single expiry notice instead of following
    /// it with another automatic window.
    func markTrialExpiryNoticeSeenIfExpired() {
        if trialHasExpired { markTrialExpiryNoticeSeen() }
    }

    /// The ONLY entitlement question. `trial`/`pro` unlock everything gated; `free`
    /// unlocks nothing. Pure given `tier`, so it's selfCheck-able.
    func isUnlocked(_ feature: Feature) -> Bool { Self.unlocked(tier: tier, feature: feature) }

    /// Short status line for the menu label, so "am I activated?" is answerable
    /// without opening the window. Pure given `tier` + `trialDaysRemaining`.
    var menuStatusLabel: String {
        switch tier {
        case .pro:   return "Wasabi Pro ✓"
        case .trial: return "Wasabi Pro — Trial: \(trialDaysRemaining) day\(trialDaysRemaining == 1 ? "" : "s") left"
        case .free:  return "Upgrade…"
        }
    }

    /// The stored key with the middle masked, for display in the activated panel
    /// (e.g. "XXXXXXXX-…-XXXXXXXXXXXX"). nil if no key. Never logs/returns the whole key.
    var maskedKey: String? {
        guard let k = storedKey(), k.count > 12 else { return storedKey() }
        return "\(k.prefix(8))…\(k.suffix(4))"
    }

    // MARK: - Activation (from the license window)

    /// Try to activate a pasted key. On success, persist the key (Keychain) + the
    /// device instance id (defaults) and stamp `lastValidated`. Returns the status
    /// for the UI to display.
    func activate(key: String) async -> LicenseStatus {
        let status = await backend.activate(key: key)
        switch status {
        case .valid(_, let instanceID):
            storeKey(key)
            if let instanceID { defaults.set(instanceID, forKey: Self.instanceIDKey) }
            defaults.set(Date(), forKey: Self.lastValidatedKey)
            defaults.set(false, forKey: Self.lastVerdictInvalidKey)
        case .invalid, .unreachable:
            break
        }
        return status
    }

    /// Background re-check on launch for an already-stored key. Updates the grace
    /// stamp on success; records an explicit invalid so the *next* launch gates.
    /// `unreachable` changes nothing (grace window carries the user).
    func revalidateInBackground() {
        guard let key = storedKey() else { return }
        let instanceID = defaults.string(forKey: Self.instanceIDKey)
        Task { [defaults, backend] in
            let status = await backend.validate(key: key, instanceID: instanceID)
            await MainActor.run {
                switch status {
                case .valid:
                    defaults.set(Date(), forKey: Self.lastValidatedKey)
                    defaults.set(false, forKey: Self.lastVerdictInvalidKey)
                case .invalid:
                    defaults.set(true, forKey: Self.lastVerdictInvalidKey)
                case .unreachable:
                    break
                }
            }
        }
    }

    /// Remove the license from this machine ("Deactivate…"). Releases the store-side
    /// activation (best-effort) before clearing local state, so the seat frees up.
    func deactivate() {
        if let key = storedKey() {
            let instanceID = defaults.string(forKey: Self.instanceIDKey)
            Task { [backend] in await backend.deactivate(key: key, instanceID: instanceID) }
        }
        deleteKey()
        defaults.removeObject(forKey: Self.instanceIDKey)
        defaults.removeObject(forKey: Self.lastValidatedKey)
        defaults.removeObject(forKey: Self.lastVerdictInvalidKey)
    }

    var isActivated: Bool { storedKey() != nil }

    // MARK: - Keychain (generic password item)

    private func storedKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private func storeKey(_ key: String) {
        deleteKey()
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: Data(key.utf8),
            // Available after first unlock, this device only — not synced to iCloud.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Self-check (ponytail: the one runnable check for the gate logic)

    /// Exercises the gate branches + stub key-format check without network or
    /// Keychain. Called at launch only when WASABI_LICENSE_SELFCHECK=1, so it
    /// never runs for users.
    static func selfCheck() {
        assert(gateDecision(hasKey: false, lastVerdictInvalid: false) == .needsKey,
               "no key → needsKey")
        assert(gateDecision(hasKey: true, lastVerdictInvalid: false) == .licensed,
               "key, not invalidated → licensed (offline never hard-locks)")
        assert(gateDecision(hasKey: true, lastVerdictInvalid: true) == .needsKey,
               "explicit store invalid → needsKey")

        // Freemium seam: isUnlocked is purely tier != .free, so one loop covers the
        // whole matrix. free locks everything; trial and pro unlock everything.
        let allFeatures: [Feature] = [.unlimitedServices, .smartSleep, .customIcons, .reorderServices]
        for f in allFeatures {
            assert(unlocked(tier: .free,  feature: f) == false, "free locks \(f)")
            assert(unlocked(tier: .trial, feature: f) == true,  "trial unlocks \(f)")
            assert(unlocked(tier: .pro,   feature: f) == true,  "pro unlocks \(f)")
        }
        // Trial window is half-open [0, N days): fail closed on a clock set back.
        assert(trialIsActive(elapsed: 0), "day 0 → active")
        assert(trialIsActive(elapsed: Double(trialDays) * 86_400 - 1), "last second → active")
        assert(!trialIsActive(elapsed: Double(trialDays) * 86_400), "exactly N days → expired")
        assert(!trialIsActive(elapsed: -1), "clock set back → expired, not active-forever")

        assert(proOfferDelay(elapsed: 0) == automaticProOfferDelay,
               "first launch → offer waits one day")
        assert(proOfferDelay(elapsed: automaticProOfferDelay - 1) == 1,
               "one second before day one → wait one second")
        assert(proOfferDelay(elapsed: automaticProOfferDelay) == 0,
               "day one → offer is due")
        assert(proOfferDelay(elapsed: -1) == automaticProOfferDelay,
               "clock rollback cannot make the offer immediately due")
        assert(softProOfferDelay(elapsed: trialDuration) == nil,
               "expired trial → skip stale day-one offer")
        assert(trialExpiryNoticeDelay(elapsed: 0) == trialDuration,
               "trial start → expiry notice waits seven days")
        assert(trialExpiryNoticeDelay(elapsed: trialDuration - 1) == 1,
               "one second before expiry → wait one second")
        assert(trialExpiryNoticeDelay(elapsed: trialDuration) == 0,
               "trial expiry → notice is due")
        assert(trialExpiryNoticeDelay(elapsed: -1) == trialDuration,
               "clock rollback cannot expire the trial")

        #if WASABI_DEV
        assert(StubLicenseBackend.looksValid("WASABI-AAAA-BBBB-CCCC"), "well-formed demo key accepted")
        assert(!StubLicenseBackend.looksValid("nope"), "junk key rejected")
        assert(!StubLicenseBackend.looksValid("WASABI-AAAA-BBBB"), "too-short key rejected")
        #endif
        DebugLog.write("license", "LicenseManager.selfCheck passed")
    }
}
