import WebKit

/// Drives the Page Visibility API for a service's WebView so inactive services
/// back off their work even while Wasabi's window is frontmost.
///
/// **Why this exists.** With `.keepRunning`, inactive services stay mounted (so
/// switching is instant — see `MainViewController.mount`). But a mounted-and-
/// `isHidden` WKWebView is still "visible" to WebKit: its timers, polling, and
/// `requestAnimationFrame` keep ticking, burning CPU/battery for a service the
/// user isn't looking at. WebKit only auto-throttles when the *window* is
/// occluded/miniaturized — not for a hidden sibling view in a frontmost window.
///
/// There is no public API to force a WKWebView's visibility state (the
/// `_setPageVisibilityState:` SPI is private). So instead we drive the page's own
/// **Page Visibility API** the same way a background browser tab does: report
/// `document.hidden = true` / `visibilityState = "hidden"` and dispatch
/// `visibilitychange`. Well-behaved web apps (WhatsApp Web, Telegram) already
/// listen for this and pause animations, throttle polling, and stop rAF loops on
/// their own — it's the standards-defined "you're in the background" signal.
///
/// This is non-destructive: we don't kill timers or rAF ourselves (that could
/// break layout). We only flip the visibility flag the page reads and let the
/// page decide how to back off. Switching back flips it to `"visible"` and fires
/// the event again, so the app resumes immediately with no remount cost.
///
/// Installed/torn down alongside the other bridges in `WebViewController`.
@MainActor
final class VisibilityBridge: NSObject {

    /// Installs the shim at document-start. The shim overrides
    /// `document.visibilityState` / `document.hidden` with values we control via
    /// `setVisible(_:on:)`, and re-dispatches `visibilitychange` when they change.
    func install(into controller: WKUserContentController, initiallyVisible: Bool) {
        let userScript = WKUserScript(
            source: Self.script(initiallyVisible: initiallyVisible),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(userScript)
    }

    /// Mark the page visible or hidden. Fires `visibilitychange` in the page so it
    /// reacts exactly as it would to a real tab background/foreground. Safe to
    /// call on a WebView that's still loading — the setter is defined at
    /// document-start, before the page's own scripts run.
    func setVisible(_ visible: Bool, on webView: WKWebView) {
        webView.evaluateJavaScript("window.__wasabiSetVisible && window.__wasabiSetVisible(\(visible));", completionHandler: nil)
    }

    /// Document-start shim. Redefines the Page Visibility getters to read a flag we
    /// flip from native. The initial value is embedded in the script so an offscreen
    /// Smart-Sleep wake is hidden from its first instruction rather than running as
    /// a foreground page until navigation finishes.
    private static func script(initiallyVisible: Bool) -> String {
        let initiallyHidden = initiallyVisible ? "false" : "true"
        return """
    (function () {
      try {
        var hidden = \(initiallyHidden);
        Object.defineProperty(document, "hidden", {
          get: function () { return hidden; },
          configurable: true
        });
        Object.defineProperty(document, "visibilityState", {
          get: function () { return hidden ? "hidden" : "visible"; },
          configurable: true
        });
        window.__wasabiSetVisible = function (visible) {
          var next = !visible;
          if (next === hidden) return;        // no change — don't spam events
          hidden = next;
          try { document.dispatchEvent(new Event("visibilitychange")); } catch (e) {}
        };
      } catch (e) {
        // Never let the shim throw into the page.
      }
    })();
    """
    }
}
