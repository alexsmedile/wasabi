import AppKit
import UserNotifications

/// App-level bridge to macOS Notification Center.
///
/// **Why this exists (the WebKit boundary):** the public WebKit API on macOS has
/// *no* Web Notification support — there is no `WKUIDelegate` permission method
/// and no `WKPreferences` flag for notifications (Safari uses private SPI we
/// can't reach). So the page's own `Notification` API is a dead end here: it's
/// what makes WhatsApp's "turn on notifications" popup hang/crash, because the
/// permission request is never answered. See `NotificationBridge`, which patches
/// `window.Notification` in the page so the request resolves and `new
/// Notification(...)` is forwarded here instead.
///
/// This manager owns the *native* side: it requests macOS authorization once and
/// posts `UNNotificationRequest`s for the forwarded web notifications. Clicking a
/// banner activates Wasabi and selects the originating service.
///
/// Sleep policy is strictly stronger than notifications: a slept service has no
/// WebContent process, emits nothing, and is never kept alive to deliver a
/// notification (see ARCHITECTURE — sleep wins).
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    /// Called when the user clicks a notification, with the originating service id.
    /// Wired by `MainViewController` to select that service.
    var onActivateService: ((String) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private var authorized = false
    private var didRequest = false

    /// Dedup ledger: maps a notification's dedup key to the time it was last
    /// posted. WhatsApp Web re-fires notifications on reload/reconnect and during
    /// smart-sleep wake windows; without this the same message banners twice.
    /// Keyed on service + JS `tag` (or service + content when no tag is given).
    private var recentlyPosted: [String: Date] = [:]
    /// A repeat of the same key within this window is treated as a duplicate.
    private let dedupWindow: TimeInterval = 30

    private override init() {
        super.init()
        center.delegate = self
    }

    /// Request macOS notification authorization once. Safe to call repeatedly —
    /// only the first call prompts; later calls just refresh the cached state.
    /// Triggered lazily the first time a hosted page asks for permission, so we
    /// never prompt at launch.
    func requestAuthorizationIfNeeded() {
        guard !didRequest else { return }
        didRequest = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor in
                self?.authorized = granted
                if let error { self?.log("authorization error: \(error.localizedDescription)") }
                self?.log("authorization granted=\(granted)")
            }
        }
    }

    /// Post a native banner for a web notification forwarded from a hosted page.
    /// `serviceID` is carried in the request so a click can reselect the service.
    /// `tag` is the JS `Notification` tag, used for dedup when present.
    func post(title: String, body: String, tag: String, serviceID: String, serviceName: String) {
        // Belt-and-suspenders: ensure we've at least asked before posting.
        requestAuthorizationIfNeeded()

        // Dedup: drop a repeat of the same notification within the window. A `tag`
        // is the page's own identity for "this is the same notification"; without
        // one, fall back to the content so reload re-fires don't double-banner.
        let key = "\(serviceID)|\(tag.isEmpty ? "\(title)\u{1}\(body)" : tag)"
        let now = Date()
        pruneDedupLedger(now: now)
        if let last = recentlyPosted[key], now.timeIntervalSince(last) < dedupWindow {
            log("deduped \(serviceID) notification (key=\(key))")
            return
        }
        recentlyPosted[key] = now

        let content = UNMutableNotificationContent()
        // Title falls back to the service name so a bodyless ping still reads
        // sensibly; subtitle always carries the service so the source is clear
        // even when the title is the chat name.
        content.title = title.isEmpty ? serviceName : title
        content.subtitle = serviceName
        content.body = body
        content.sound = .default
        // Thread by service so macOS groups WhatsApp pings together, Telegram's
        // separately, etc.
        content.threadIdentifier = serviceID
        content.userInfo = ["serviceID": serviceID]

        // Immediate delivery (nil trigger). A fresh UUID per request prevents the
        // system from coalescing distinct messages into one.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { [weak self] error in
            if let error {
                Task { @MainActor in self?.log("post failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Drop dedup-ledger entries older than the window so the map can't grow
    /// unbounded over a long session.
    private func pruneDedupLedger(now: Date) {
        recentlyPosted = recentlyPosted.filter { now.timeIntervalSince($0.value) < dedupWindow }
    }

    private func log(_ msg: @autoclosure () -> String) {
        DebugLog.write("notifications", msg())
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Show banners even when Wasabi is frontmost — a chat app's notifications are
    /// still useful when you're looking at a *different* service.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Clicking a notification activates Wasabi and selects the service it came from.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let serviceID = response.notification.request.content.userInfo["serviceID"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let serviceID { NotificationManager.shared.onActivateService?(serviceID) }
            completionHandler()
        }
    }
}
