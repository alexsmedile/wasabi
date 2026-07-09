import AppKit
import WebKit

/// Resolves and caches a service's real favicon from its live WKWebView.
///
/// Strategy: once a page finishes loading, ask the DOM for the best icon link
/// (`apple-touch-icon` > sized `rel=icon` > `/favicon.ico`), fetch it, decode to
/// an `NSImage`, and cache it on disk keyed by service id. The sidebar shows the
/// service's SF Symbol as an instant placeholder and offline fallback; when the
/// real icon arrives, `onResolved` swaps it in. No bundled assets, and it tracks
/// whatever icon the site actually serves — so new services work for free.
@MainActor
final class FaviconProvider {
    static let shared = FaviconProvider()

    /// Called on the main actor when a service's favicon resolves to an image.
    var onResolved: ((_ serviceID: String, _ image: NSImage) -> Void)?

    private var cache: [String: NSImage] = [:]
    /// Services whose favicon we've already resolved this session — so we don't
    /// re-run the DOM query + network fetch on every `didFinish` (SPAs fire many,
    /// and smart-sleep wakes fire more). The disk cache persists across launches.
    private var resolvedThisSession: Set<String> = []
    private let cacheDir: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = base.appendingPathComponent("app.wasabi.Wasabi/favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// The cached icon for a service, if one has been resolved (memory or disk).
    func cachedIcon(for serviceID: String) -> NSImage? {
        if let img = cache[serviceID] { return img }
        let url = diskURL(for: serviceID)
        if let img = NSImage(contentsOf: url) {
            cache[serviceID] = img
            return img
        }
        return nil
    }

    /// Evict a service's favicon entirely — memory cache, the
    /// resolved-this-session marker, and the on-disk file. Called when a service is
    /// removed so a re-added service reusing the id (or the disk slot) can't show a
    /// stale icon.
    func evict(serviceID: String) {
        cache[serviceID] = nil
        resolvedThisSession.remove(serviceID)
        try? FileManager.default.removeItem(at: diskURL(for: serviceID))
    }

    /// Resolve the favicon from a loaded WebView. Idempotent-ish: safe to call on
    /// every `didFinish`; it simply refreshes the cached icon if the site's icon
    /// changed. Cheap when nothing changed (one small JS call + a conditional GET-less fetch).
    func resolve(for serviceID: String, from webView: WKWebView, force: Bool = false) {
        // Already resolved this session — skip the DOM query + network fetch.
        // Pass `force: true` to deliberately re-check (e.g. a manual refresh).
        if !force, resolvedThisSession.contains(serviceID) { return }
        let js = """
        (function () {
          function abs(href) { try { return new URL(href, document.baseURI).href; } catch (e) { return null; } }
          var best = null, bestSize = -1;
          var links = document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"], link[rel="shortcut icon"]');
          for (var i = 0; i < links.length; i++) {
            var l = links[i];
            var sizes = (l.getAttribute('sizes') || '').match(/\\d+/);
            var apple = /apple-touch-icon/.test(l.getAttribute('rel') || '');
            var size = sizes ? parseInt(sizes[0], 10) : (apple ? 180 : 32);
            if (size > bestSize && l.href) { bestSize = size; best = l.href; }
          }
          return abs(best || '/favicon.ico');
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let urlString = result as? String, let url = URL(string: urlString) else { return }
            self.fetch(url, for: serviceID)
        }
    }

    // MARK: - Private

    private func fetch(_ url: URL, for serviceID: String) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // Reuse HTTP cache when fresh; favicons rarely change between launches.
        request.cachePolicy = .returnCacheDataElseLoad
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data, let image = NSImage(data: data), image.size.width > 0 else { return }
            Task { @MainActor in self.store(image, data: data, for: serviceID) }
        }.resume()
    }

    private func store(_ image: NSImage, data: Data, for serviceID: String) {
        cache[serviceID] = image
        resolvedThisSession.insert(serviceID)
        try? data.write(to: diskURL(for: serviceID))
        onResolved?(serviceID, image)
    }

    private func diskURL(for serviceID: String) -> URL {
        cacheDir.appendingPathComponent("\(serviceID).img")
    }
}
