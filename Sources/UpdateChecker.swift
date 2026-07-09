import AppKit

/// Lightweight update NOTIFIER (not an installer). Reads a tiny JSON manifest off
/// a public static host and, if it advertises a newer version than the running
/// build, offers a "Download" that opens the DMG page in the browser. Zero
/// dependencies, no framework — see requests/update-channel/PLAN.md for why this
/// is deliberately not Sparkle.
///
/// An automatic (launch) check is silent unless an update exists and never shows
/// an error; a menu-triggered check reports up-to-date explicitly.
@MainActor
final class UpdateChecker: NSObject {
    /// Shared target for the menu item's @objc selector (NSObject required).
    static let shared = UpdateChecker()

    /// The manifest URL. Placeholder until the first update is hosted (own domain /
    /// S3 / public releases repo — see PLAN). No automatic check fires while this is
    /// a placeholder, so it can't nag against a dead URL.
    static let feedURL = URL(string: "https://updates.wasabi.app/latest.json")
    private static let isConfigured = feedURL?.host != "updates.wasabi.app"  // flip when real host is set

    struct Manifest: Decodable {
        let version: String
        let url: String
        let notes: String?
    }

    /// Fire-and-forget check for launch. Silent on: not configured, unreachable,
    /// same-or-older version. Only surfaces UI when a newer version exists.
    static func checkInBackground() {
        guard isConfigured, let feedURL else { return }
        Task {
            guard let m = await fetch(feedURL),
                  isNewer(m.version, than: currentVersion) else { return }
            presentUpdate(m)
        }
    }

    /// User-initiated ("Check for Updates…") menu action. Instance method so it can
    /// be an @objc selector target; delegates to the static check.
    @objc func checkForUpdatesFromMenu() { Self.checkFromMenu() }

    /// Always reports a result (up-to-date or available).
    static func checkFromMenu() {
        guard let feedURL else {
            report(title: "Updates unavailable", body: "No update source is configured yet.")
            return
        }
        Task {
            guard let m = await fetch(feedURL) else {
                report(title: "Couldn't check for updates",
                       body: "Please try again later, or visit the Wasabi site.")
                return
            }
            if isNewer(m.version, than: currentVersion) {
                presentUpdate(m)
            } else {
                report(title: "You're up to date",
                       body: "Wasabi \(currentVersion) is the latest version.")
            }
        }
    }

    // MARK: - Fetch

    private static func fetch(_ url: URL) async -> Manifest? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return m
    }

    // MARK: - Version compare

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True if `candidate` is a strictly newer version than `current`.
    /// Compares dotted numeric components; a `-beta`/`-suffix` build sorts BEFORE
    /// the same numeric release (0.5.0-beta < 0.5.0). ponytail: 3-field
    /// hand-compare beats a semver dependency here.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let (cNums, cPre) = split(candidate)
        let (curNums, curPre) = split(current)
        let n = max(cNums.count, curNums.count)
        for i in 0..<n {
            let a = i < cNums.count ? cNums[i] : 0
            let b = i < curNums.count ? curNums[i] : 0
            if a != b { return a > b }
        }
        // Numeric parts equal → a release (no pre) outranks a pre-release.
        if cPre == curPre { return false }
        if cPre && !curPre { return false }   // candidate is pre, current is release → not newer
        if !cPre && curPre { return true }    // candidate is release, current is pre → newer
        return false
    }

    /// "0.5.0-beta" → ([0,5,0], hasPrerelease: true).
    private static func split(_ v: String) -> ([Int], Bool) {
        let core = v.split(separator: "-", maxSplits: 1)
        let hasPre = core.count > 1
        let nums = core[0].split(separator: ".").map { Int($0) ?? 0 }
        return (nums, hasPre)
    }

    // MARK: - UI (AppKit alerts — explicit, user-facing)

    private static func presentUpdate(_ m: Manifest) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = "Wasabi \(m.version) is available (you have \(currentVersion))."
            + (m.notes.map { "\n\n\($0)" } ?? "")
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: m.url) {
            NSWorkspace.shared.open(url)
        }
    }

    private static func report(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Self-check (ponytail: the one runnable check for version compare)

    static func selfCheck() {
        assert(isNewer("0.5.0", than: "0.4.0"), "0.5.0 > 0.4.0")
        assert(isNewer("0.4.1", than: "0.4.0"), "0.4.1 > 0.4.0")
        assert(isNewer("1.0.0", than: "0.9.9"), "1.0.0 > 0.9.9")
        assert(!isNewer("0.4.0", than: "0.4.0"), "equal is not newer")
        assert(!isNewer("0.3.0", than: "0.4.0"), "older is not newer")
        assert(isNewer("0.5.0", than: "0.5.0-beta"), "release > same-version beta")
        assert(!isNewer("0.5.0-beta", than: "0.5.0"), "beta < same-version release")
        assert(isNewer("0.5.0-beta", than: "0.4.0"), "newer beta > older release")
        assert(!isNewer("0.4.0-beta", than: "0.4.0-beta"), "equal betas not newer")
        DebugLog.write("update", "UpdateChecker.selfCheck passed")
    }
}
