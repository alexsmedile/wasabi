import AppKit
import WebKit

/// Owns exactly one WKWebView for one service.
///
/// Responsibilities: build the WKWebView with an isolated, *persistent* data
/// store, set the desktop-Safari customUserAgent, load the service URL, and
/// tear the WebView down on `sleep()` to release its WebKit content process
/// (the only way to reclaim the per-service RAM). Because the data store is
/// persistent, `wake()` restores the session without re-login.
///
/// See .spectacular/ARCHITECTURE.md § Per-service WebView lifecycle.
@MainActor
final class WebViewController: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    /// The service this controller hosts. `var` so an Edit (rename / URL change)
    /// can update it in place while keeping the same `id` — and thus the same
    /// isolated data store and stored policy. Only the URL affects loading.
    private(set) var service: Service

    /// Backing store — nil while asleep. Built lazily on first access / wake.
    private var _webView: WKWebView?
    private var didLoad = false
    private var downloads: [ObjectIdentifier: WKDownload] = [:]

    /// Patches `window.Notification` so the page's notification permission request
    /// is answered (the crash fix) and `new Notification(...)` is forwarded to
    /// macOS. Rebuilt alongside the WebView; torn down on sleep.
    private lazy var notificationBridge = NotificationBridge(service: service)

    /// Shims `navigator.clipboard` so writeText/write(image) work via NSPasteboard.
    /// WKWebView denies the Clipboard API by default; without this shim, WhatsApp's
    /// "Copy" context menu writes a URL instead of text/image data.
    private lazy var clipboardBridge = ClipboardBridge()

    /// Drives the Page Visibility API so an inactive or app-backgrounded service
    /// reports `document.hidden = true` and backs off its timers/rAF. Rebuilt
    /// alongside the WebView.
    private lazy var visibilityBridge = VisibilityBridge()

    /// Desired page-visibility for this service (active = visible). Remembered so
    /// it can be re-asserted once a page finishes loading — a service that loads
    /// while inactive must end up `hidden`, not stuck at the shim's `visible`
    /// default. Defaults to `true` so the first (active) service loads visible.
    private var desiredVisible = true

    /// True from `sleep()` until the first `didFinish` after the next wake. Lets the
    /// UI show a "waking…" overlay only for a real cold reload (masking the blank
    /// rebuilt WebView), not for ordinary in-page navigations.
    private(set) var wasSlept = false

    /// One-shot callback for the next completed page load. `MainViewController`
    /// uses it to fade out the wake overlay once the reloaded page is on screen.
    var onDidFinish: (() -> Void)?

    /// One-shot completion used by `WebViewPool` for an offscreen Smart-Sleep
    /// wake. `true` means the main-frame navigation finished; `false` means it
    /// failed or its content process terminated. Keeping this separate from
    /// `onDidFinish` avoids the pool clobbering the UI's wake-overlay callback.
    private var backgroundLoadCompletion: ((Bool) -> Void)?

    /// The live WebView, created on demand. Accessing it after `sleep()`
    /// transparently rebuilds it (still backed by the same persistent store).
    var webView: WKWebView {
        if let existing = _webView { return existing }
        let fresh = makeWebView()
        _webView = fresh
        return fresh
    }

    var canGoBack: Bool { _webView?.canGoBack ?? false }

    init(service: Service) {
        self.service = service
        super.init()
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()

        // Isolated, persistent per-service session. A stable per-service UUID
        // keys an on-disk store so logins/cookies survive sleep/wake and app
        // restarts, and never cross between services.
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: DataStoreID.uuid(for: service.id))

        // Let web apps manage their own media playback (voice messages, etc.).
        config.mediaTypesRequiringUserActionForPlayback = []

        // Install the Web Notification shim at document start. WKWebView has no
        // working Notification API on macOS, so without this the page's permission
        // request hangs/crashes (the "turn on notifications" popup). The bridge
        // answers the request and forwards posted notifications to macOS.
        notificationBridge.install(into: config.userContentController)
        clipboardBridge.install(into: config.userContentController)
        visibilityBridge.install(
            into: config.userContentController,
            initiallyVisible: desiredVisible
        )

        // A WKWebView subclass that does NOT register file URLs as a drag type, so
        // dropping a PDF/image onto the page reaches the web app's own JS drop zone
        // instead of WebKit navigating to (and rendering) the file. See NonNavigatingWebView.
        let webView = NonNavigatingWebView(frame: .zero, configuration: config)
        webView.customUserAgent = UserAgent.desktopSafari   // required — see DECISIONS.md
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        // The UI delegate provides the native file-open panel for <input type=file>;
        // without it, clicking an attach button does nothing (or crashes).
        webView.uiDelegate = self

        // Font crispness: a layer-backed WebView over a non-opaque backdrop loses
        // the opaque-background path that macOS text antialiasing relies on, so
        // glyphs render thin/fuzzy. Give the WebView an opaque white drawing
        // surface so AA composites against a solid background (matches Safari).
        webView.wantsLayer = true
        webView.layer?.isOpaque = true
        webView.layer?.backgroundColor = NSColor.white.cgColor

        return webView
    }

    private func log(_ msg: @autoclosure () -> String) {
        DebugLog.write(service.id, msg())
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // A file dropped on the page must never become a navigation — that's the
        // "dropped PDF opens in-view instead of attaching" bug. Cancel any main-
        // frame navigation to a file:// URL here, deterministically, and let the
        // page's own DOM drop handler keep the file for upload. We do NOT strip
        // the file drag types from the view (the old NonNavigatingWebView trick):
        // WebKit needs those types registered to populate DataTransfer.files, and
        // stripping them raced WebContent-process relaunches (shared pool + sleep),
        // producing the "drop overlay shows but nothing uploads" intermittency.
        if url.isFileURL {
            decisionHandler(.cancel)
            return
        }

        if shouldOpenNonWebSchemeExternally(url) {
            openExternal(url)
            decisionHandler(.cancel)
        } else if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if shouldDownload(navigationResponse) {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        retain(download)
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        retain(download)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.log("didFinish: \(webView.url?.absoluteString ?? "?") title=\(webView.title ?? "")")
            // Resolve the real site favicon for the sidebar icon (cached on disk).
            FaviconProvider.shared.resolve(for: self.service.id, from: webView)
            // Re-assert visibility in case focus or service selection changed while
            // navigation was in flight. The document-start shim already had the
            // correct initial value, so this is synchronization rather than repair.
            self.visibilityBridge.setVisible(self.desiredVisible, on: webView)
            // The rebuilt page is on screen now — clear the wake flag and let the UI
            // fade out its "waking" overlay.
            self.wasSlept = false
            self.finishBackgroundLoad(success: true)
            let completion = self.onDidFinish
            self.onDidFinish = nil
            completion?()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.log("didFail: \(error.localizedDescription)")
            self.finishBackgroundLoad(success: false)
        }
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let destination = uniqueDownloadURL(for: suggestedFilename)
        log("downloadDestination: \(destination.path)")
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        log("downloadDidFinish")
        release(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        log("downloadDidFail: \(error.localizedDescription)")
        release(download)
    }

    // MARK: - WKUIDelegate (file upload)

    /// Web apps often open meeting/share links with `target=_blank` or
    /// `window.open`. WKWebView does not create a window by default, so those
    /// clicks appear dead unless the UI delegate handles the request.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else {
            return nil
        }

        if shouldOpenNewWindowExternally(url) {
            openExternal(url)
        } else {
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// Grant mic/camera access when a web app calls getUserMedia().
    /// Without this delegate method WKWebView silently denies all media capture requests.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    /// Present the native file picker when the page activates an `<input type=file>`.
    /// WKWebView has no built-in panel; without this delegate method the input does
    /// nothing. The completion handler MUST be called exactly once (with the chosen
    /// URLs or `nil` for cancel) — failing to call it is what crashes the WebContent
    /// process. Honors `multiple` and `accept` via the supplied parameters.
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true

        guard let window = webView.window else {
            // No window to attach a sheet to — run modally and always answer the handler.
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    private func shouldOpenNonWebSchemeExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https", "about", "data", "blob":
            return false
        default:
            return true
        }
    }

    private func shouldOpenNewWindowExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https":
            return !isSameServiceHost(url)
        case "about", "data", "blob":
            return false
        default:
            return true
        }
    }

    private func isSameServiceHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              let serviceHost = service.url.host?.lowercased() else {
            return false
        }
        return host == serviceHost || host.hasSuffix(".\(serviceHost)")
    }

    private func openExternal(_ url: URL) {
        log("openExternal: \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    private func shouldDownload(_ navigationResponse: WKNavigationResponse) -> Bool {
        guard navigationResponse.isForMainFrame else { return false }
        if !navigationResponse.canShowMIMEType { return true }

        guard let mimeType = navigationResponse.response.mimeType?.lowercased() else {
            return false
        }

        return !Self.webDocumentMIMETypes.contains(mimeType)
    }

    private static let webDocumentMIMETypes: Set<String> = [
        "text/html",
        "application/xhtml+xml",
    ]

    private func retain(_ download: WKDownload) {
        downloads[ObjectIdentifier(download)] = download
        download.delegate = self
        log("downloadStarted")
    }

    private func release(_ download: WKDownload) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
    }

    private func uniqueDownloadURL(for suggestedFilename: String) -> URL {
        let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        let filename = sanitizedFilename(suggestedFilename.isEmpty ? "download" : suggestedFilename)
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        var candidate = downloadsDirectory.appendingPathComponent(filename)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = downloadsDirectory.appendingPathComponent(numbered)
            index += 1
        }
        return candidate
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let cleaned = filename
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : cleaned
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.log("didFailProvisional: \(error.localizedDescription)")
            self.finishBackgroundLoad(success: false)
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.log("WebContent process terminated")
            if self._webView === webView {
                // Do not auto-reload here: a crashing page would become an
                // unbounded reload loop. A later selection or explicit reload is
                // the recovery boundary; Smart Sleep treats this wake as failed.
                self.didLoad = false
            }
            self.finishBackgroundLoad(success: false)
        }
    }

    /// Load the service URL once. Idempotent — repeated calls are no-ops.
    /// After `sleep()`, `didLoad` is reset so the next call reloads on wake.
    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        webView.load(URLRequest(url: service.url))
    }

    func goBackIfPossible() {
        guard let live = _webView, live.canGoBack else { return }
        live.goBack()
    }

    /// Reload the current page in place (no teardown — the session and data store
    /// are untouched). No-op while asleep: a slept service reloads cold on the next
    /// wake anyway, so there's nothing to refresh.
    func reload() {
        _webView?.reload()
    }

    /// Apply an edited service (same id). If the URL changed, reload to the new
    /// address and re-resolve the favicon; a name-only change needs no reload.
    func updateService(_ updated: Service) {
        let urlChanged = updated.url != service.url
        service = updated
        guard urlChanged else { return }
        FaviconProvider.shared.evict(serviceID: updated.id)   // host changed → drop stale icon
        if let live = _webView {
            didLoad = true
            live.load(URLRequest(url: updated.url))
        } else {
            didLoad = false   // asleep: next wake loads the new URL
        }
    }

    /// Tell the page whether it's the visible (active) service. Drives the Page
    /// Visibility API so an inactive service backs off its timers/rAF/polling
    /// without being torn down. No-op while asleep (no page to signal — it will
    /// load fresh as "visible" on wake, and the caller marks it inactive if so).
    func setVisible(_ visible: Bool) {
        desiredVisible = visible
        guard let live = _webView else { return }
        visibilityBridge.setVisible(visible, on: live)
    }

    /// Observe exactly one navigation attempt made for an offscreen Smart-Sleep
    /// wake. Replacing an existing observer invalidates the older wake generation.
    func observeBackgroundLoad(_ completion: @escaping (Bool) -> Void) {
        backgroundLoadCompletion = completion
    }

    func cancelBackgroundLoadObservation() {
        backgroundLoadCompletion = nil
    }

    private func finishBackgroundLoad(success: Bool) {
        guard let completion = backgroundLoadCompletion else { return }
        backgroundLoadCompletion = nil
        completion(success)
    }

    // MARK: - Sleep / wake

    /// Tear down the WebView to reclaim memory. The WKWebView (and its backing
    /// `com.apple.WebKit.WebContent` XPC process) is released, freeing the
    /// per-service heap. The persistent data store on disk is untouched, so a
    /// later `wake()` restores the session with no re-login.
    /// Whether the WebContent process is live (WebView built) vs. slept (released).
    /// Drives the sidebar status dot.
    var isAwake: Bool { _webView != nil }

    func sleep() {
        guard let live = _webView else { return }          // already asleep
        live.stopLoading()
        live.navigationDelegate = nil
        // Release the script-message handlers so the bridge doesn't retain the
        // (about-to-be-freed) content controller. The next makeWebView() reinstalls.
        notificationBridge.uninstall(from: live.configuration.userContentController)
        clipboardBridge.uninstall(from: live.configuration.userContentController)
        live.removeFromSuperview()
        cancelBackgroundLoadObservation()
        _webView = nil
        didLoad = false
        wasSlept = true
        log("slept — WebView released")
    }

    /// Recreate the WebView (if needed) and reload from the persistent store.
    /// Returns the live WebView so the caller can remount it.
    @discardableResult
    func wake() -> WKWebView {
        let view = webView          // rebuilds via the computed accessor if asleep
        loadIfNeeded()
        return view
    }
}
