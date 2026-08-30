import Foundation

/// How aggressively a service's WKWebView is torn down to reclaim RAM.
///
/// Enforced by `WebViewPool`. Tearing down a WKWebView releases its WebKit
/// content process and reclaims the per-service heap (proven in M1: WhatsApp
/// 743MB → 0). Waking reloads from the persistent data store — no re-login.
///
/// See .spectacular/ARCHITECTURE.md § Sleep-policy state machine.
enum SleepPolicy: Hashable {
    /// Stay LIVE even when not the active service. Highest RAM, instant switch.
    case keepRunning
    /// Sleep after `seconds` of being inactive (default 5 min). Instant switch
    /// within the window; teardown once you've clearly moved on.
    case autoSleepTimer(TimeInterval)
    /// Sleep when inactive, then periodically wake to sync + refresh the unread
    /// badge, sleeping again between cycles. Wake interval adapts to idleness.
    case smartSleep

    /// Default idle timeout for the timer policy.
    static let defaultTimeout: TimeInterval = 5 * 60

    /// Convenience: the timer policy at the default timeout.
    static var sleepAfterDefault: SleepPolicy { .autoSleepTimer(defaultTimeout) }
}

// MARK: - Persistence (UserDefaults string encoding)

extension SleepPolicy {
    /// Stable string form for UserDefaults (key `wasabi.sleeppolicy.<id>`).
    var rawString: String {
        switch self {
        case .keepRunning:            return "keepRunning"
        case .autoSleepTimer(let t):  return "timer:\(Int(t))"
        case .smartSleep:             return "smart"
        }
    }

    init?(rawString: String) {
        if rawString == "keepRunning" { self = .keepRunning; return }
        if rawString == "smart" { self = .smartSleep; return }
        if rawString.hasPrefix("timer:"),
           let secs = TimeInterval(rawString.dropFirst("timer:".count)) {
            self = .autoSleepTimer(secs)
            return
        }
        return nil
    }
}

// MARK: - Codable (encode as the stable rawString)

extension SleepPolicy: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let policy = SleepPolicy(rawString: raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown sleep policy: \(raw)")
        }
        self = policy
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawString)
    }
}

// MARK: - Smart-sleep adaptive schedule

/// Adaptive wake intervals for `smartSleep`. The longer a service has been
/// idle, the longer we wait between background wake-and-sync cycles — spend
/// RAM/cycles where they matter, back off when the user clearly isn't looking.
///
/// Tune here: these are the only knobs that shape smart-sleep cadence.
enum SmartSleepSchedule {
    /// (idle-at-least, then-wake-every) buckets, longest idle first.
    static let buckets: [(idleAtLeast: TimeInterval, wakeEvery: TimeInterval)] = [
        (idleAtLeast: 60 * 60, wakeEvery: 60 * 60),   // idle ≥ 1h  → wake every 60m
        (idleAtLeast: 30 * 60, wakeEvery: 15 * 60),   // idle ≥ 30m → wake every 15m
        (idleAtLeast:       0, wakeEvery:  5 * 60),   // recent     → wake every 5m
    ]

    /// Stop automatic wakes after repeated failures. Selecting the service or
    /// changing its policy resets the breaker and gives it a clean retry boundary.
    static let maxConsecutiveFailures = 3

    /// Grace period after you switch *away* before the first teardown. Keeps the
    /// service live briefly so flicking between services (or a quick glance
    /// elsewhere and back) doesn't pay a full teardown + cold reload. Switch back
    /// within this window and the service was never slept. After it elapses the
    /// adaptive wake cycle begins.
    ///
    /// Two windows, keyed on app focus (see `WebViewPool.grace`):
    ///   • `graceForeground` — Wasabi is frontmost: you're still navigating other
    ///     tabs and may flip back to reply, so hold the just-left service live for
    ///     a few minutes (a message can land in that gap — don't sleep under you).
    ///   • `graceBackground`  — you Cmd-Tabbed to another app: you've clearly left,
    ///     so tear down sooner and reclaim the RAM.
    static let graceForeground: TimeInterval = 3 * 60
    static let graceBackground: TimeInterval = 60

    /// Maximum time an offscreen wake may spend loading. A failed or stalled load
    /// is torn down and retried later with exponential backoff.
    static let loadTimeout: TimeInterval = 30

    /// How long to stay awake after navigation completes, letting the service
    /// finish websocket reconnects and refresh its badge.
    static let syncWindow: TimeInterval = 8

    /// Next wake interval given how long the service has been idle.
    static func wakeInterval(idleFor idle: TimeInterval, consecutiveFailures: Int = 0) -> TimeInterval {
        let base = buckets.first(where: { idle >= $0.idleAtLeast })?.wakeEvery
            ?? buckets.last!.wakeEvery
        let multiplier = 1 << min(max(consecutiveFailures, 0), 3)
        return min(base * TimeInterval(multiplier), 60 * 60)
    }
}
