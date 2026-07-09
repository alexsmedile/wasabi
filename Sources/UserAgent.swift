import Foundation

/// Canonical desktop-Safari user-agent string applied to every WKWebView.
///
/// WhatsApp Web sniffs the UA and shows a "Browser not supported" wall when it
/// sees a non-Safari desktop UA — which is the default WKWebView behavior.
/// Setting `WKWebView.customUserAgent` to a current desktop-Safari string is the
/// Apple-sanctioned fix. See .spectacular/DECISIONS.md.
///
/// If WhatsApp ever rejects this string again, bump the Safari/WebKit versions
/// here to match the current macOS Safari (check `navigator.userAgent` in Safari).
enum UserAgent {
    static let desktopSafari =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
        "Version/18.0 Safari/605.1.15"
}
