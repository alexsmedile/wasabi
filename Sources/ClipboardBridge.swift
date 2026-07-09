import AppKit
import WebKit

/// Shims `navigator.clipboard` for WKWebView.
///
/// macOS WKWebView denies the Clipboard API by default — `writeText()` and
/// `write()` both reject silently, so web apps that rely on them (WhatsApp Web's
/// "Copy" context menu, image copy) fall back to writing a URL or doing nothing.
///
/// This bridge injects a script at document-start that replaces
/// `navigator.clipboard` with a native-backed shim:
///   - `writeText(text)`  → posts to the "clipboardWrite" handler → NSPasteboard
///   - `write([ClipboardItem])` → reads each item's blob, base64-encodes it,
///     posts to "clipboardWrite" handler → NSPasteboard (image/png supported)
///
/// The shim resolves the Promise immediately (optimistic) so the calling page
/// doesn't see a rejection. The native side writes asynchronously but fast enough
/// that any follow-up read from another app gets the correct data.
@MainActor
final class ClipboardBridge: NSObject, WKScriptMessageHandler {

    private static let handlerName = "clipboardWrite"

    private static let script = """
    (function () {
      function postClip(msg) {
        window.webkit.messageHandlers.clipboardWrite.postMessage(msg);
      }

      const shimClipboard = {
        writeText: function (text) {
          postClip({ type: 'text', text: String(text) });
          return Promise.resolve();
        },
        write: function (items) {
          try {
            var promises = items.map(function (item) {
              // ClipboardItem exposes types[] and getType(mimeType) → Promise<Blob>
              var types = Array.from(item.types || []);
              // Rich-text copy (ChatGPT's copy buttons, code blocks, ⌘C) writes a
              // ClipboardItem of text/plain — route it through the text path, not
              // the image one, or the bytes get NSImage-decoded to nil and dropped.
              if (types.indexOf('text/plain') >= 0) {
                return item.getType('text/plain').then(function (blob) {
                  return blob.text().then(function (text) {
                    postClip({ type: 'text', text: text });
                  });
                });
              }
              var mimeType = types.indexOf('image/png') >= 0 ? 'image/png'
                           : types.indexOf('image/jpeg') >= 0 ? 'image/jpeg'
                           : types[0];
              if (!mimeType) return Promise.resolve();
              return item.getType(mimeType).then(function (blob) {
                return new Promise(function (resolve) {
                  var reader = new FileReader();
                  reader.onloadend = function () {
                    // result is "data:<mime>;base64,<data>"
                    postClip({ type: 'image', mime: mimeType, data: reader.result });
                    resolve();
                  };
                  reader.readAsDataURL(blob);
                });
              });
            });
            return Promise.all(promises).then(function () {});
          } catch (e) {
            return Promise.reject(e);
          }
        },
        readText: function () {
          // Read is not bridged — return what the OS clipboard has via execCommand
          return Promise.resolve('');
        },
        read: function () {
          return Promise.resolve([]);
        }
      };

      try {
        Object.defineProperty(navigator, 'clipboard', {
          get: function () { return shimClipboard; },
          configurable: true
        });
      } catch (e) {
        // navigator.clipboard may be a non-configurable accessor on some WebKit
        // builds — fall back to a plain assignment so the shim still takes effect.
        try { navigator.clipboard = shimClipboard; } catch (e2) {}
      }
    })();
    """

    func install(into controller: WKUserContentController) {
        let userScript = WKUserScript(
            source: Self.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        controller.addUserScript(userScript)
        controller.add(self, name: Self.handlerName)
    }

    func uninstall(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.handlerName)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        // IMPORTANT: validate fully *before* clearing the pasteboard. Clearing
        // first then bailing on a malformed payload would wipe the user's
        // existing clipboard and write nothing.
        let pb = NSPasteboard.general

        switch type {
        case "text":
            guard let text = body["text"] as? String else { return }
            pb.clearContents()
            pb.setString(text, forType: .string)

        case "image":
            guard let dataURL = body["data"] as? String,
                  let commaIdx = dataURL.firstIndex(of: ",") else { return }
            let base64 = String(dataURL[dataURL.index(after: commaIdx)...])
            guard let imageData = Data(base64Encoded: base64) else { return }

            // Write the raw, original-format bytes so the target app receives the
            // image losslessly (PNG stays PNG). Re-encoding via NSImage can yield
            // TIFF in some apps. Fall back to .tiff via NSImage only if the MIME
            // is one we don't have a pasteboard type for.
            let mime = (body["mime"] as? String)?.lowercased() ?? "image/png"
            let pbType: NSPasteboard.PasteboardType?
            switch mime {
            case "image/png":  pbType = .png
            case "image/tiff": pbType = .tiff
            default:           pbType = nil   // jpeg and others: route through NSImage
            }

            if let pbType {
                pb.clearContents()
                pb.setData(imageData, forType: pbType)
            } else if let image = NSImage(data: imageData) {
                pb.clearContents()
                pb.writeObjects([image])
            }

        default:
            break
        }
    }
}
