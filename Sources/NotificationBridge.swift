import WebKit

/// Per-service bridge that makes the Web Notification API work under WKWebView.
///
/// **The crash fix.** macOS WKWebView ships no working Web Notification support
/// (no permission delegate, no preference — see `NotificationManager`). When
/// WhatsApp calls `Notification.requestPermission()` the request is never
/// answered, which is what hangs the "turn on notifications" popup and can crash
/// the WebContent process. We replace `window.Notification` at document start
/// with a shim that:
///   1. reports permission as `"granted"` and resolves `requestPermission()`
///      immediately (so the page proceeds instead of hanging), and
///   2. forwards every `new Notification(title, opts)` to native code via a
///      `WKScriptMessageHandler`, which re-emits it through Notification Center.
///
/// Installed once per `WebViewController` against its WebView's
/// `userContentController`. The message handler is added with a weak-ish owner so
/// tearing down the WebView on sleep releases it cleanly.
@MainActor
final class NotificationBridge: NSObject, WKScriptMessageHandler {
    static let messageName = "wasabiNotify"
    static let permissionMessageName = "wasabiNotifyPermission"

    private let service: Service

    init(service: Service) {
        self.service = service
        super.init()
    }

    /// Inject the shim and register the message handlers on a content controller.
    func install(into controller: WKUserContentController) {
        let script = WKUserScript(
            source: Self.shimSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        controller.addUserScript(script)
        controller.add(self, name: Self.messageName)
        controller.add(self, name: Self.permissionMessageName)
    }

    /// Remove handlers before the WebView is torn down (avoids dangling handler
    /// registration; user scripts are owned by the controller and go with it).
    func uninstall(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.messageName)
        controller.removeScriptMessageHandler(forName: Self.permissionMessageName)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case Self.permissionMessageName:
            // The page asked for permission — surface the native macOS prompt once.
            NotificationManager.shared.requestAuthorizationIfNeeded()

        case Self.messageName:
            guard let body = message.body as? [String: Any] else { return }
            let title = body["title"] as? String ?? ""
            let text = body["body"] as? String ?? ""
            let tag = body["tag"] as? String ?? ""
            NotificationManager.shared.post(
                title: title, body: text, tag: tag,
                serviceID: service.id, serviceName: service.name
            )

        default:
            break
        }
    }

    /// The JS shim, injected at document start so it's in place before the page's
    /// own scripts read `window.Notification`.
    private static let shimSource = """
    (function () {
      try {
        const post = (name, payload) => {
          const h = window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers[name];
          if (h) h.postMessage(payload || {});
        };

        function WasabiNotification(title, options) {
          options = options || {};
          this.title = title;
          this.body = options.body || "";
          this.tag = options.tag || "";
          post("\(messageName)", {
            title: String(title || ""),
            body: String(this.body),
            tag: String(this.tag),
          });
          // Fire onshow asynchronously so callers that set it inline still see it.
          const self = this;
          setTimeout(() => { if (typeof self.onshow === "function") self.onshow(); }, 0);
        }

        // Methods/events the page may call — make them harmless no-ops.
        WasabiNotification.prototype.close = function () {
          if (typeof this.onclose === "function") this.onclose();
        };
        WasabiNotification.prototype.addEventListener = function () {};
        WasabiNotification.prototype.removeEventListener = function () {};

        // Permission model: report granted, resolve requests immediately. This is
        // the line that stops WhatsApp's permission popup from hanging/crashing.
        Object.defineProperty(WasabiNotification, "permission", {
          get: function () { return "granted"; },
          configurable: true,
        });
        WasabiNotification.requestPermission = function (cb) {
          post("\(permissionMessageName)");
          if (typeof cb === "function") { try { cb("granted"); } catch (e) {} }
          return Promise.resolve("granted");
        };
        WasabiNotification.maxActions = 0;

        // Install over the (broken/absent) native one.
        try {
          Object.defineProperty(window, "Notification", {
            value: WasabiNotification,
            writable: true,
            configurable: true,
          });
        } catch (e) {
          window.Notification = WasabiNotification;
        }
      } catch (e) {
        // Never let the shim throw into the page.
      }
    })();
    """
}
