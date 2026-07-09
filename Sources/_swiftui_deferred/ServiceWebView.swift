import SwiftUI
import WebKit

/// Hosts a service's WKWebView inside SwiftUI.
///
/// The WKWebView is owned by the long-lived WebViewController (passed in), not
/// created here — so switching services in the sidebar never tears down or
/// reloads a WebView in M1. Updating `nsView` just swaps which WebView is shown.
struct ServiceWebView: NSViewRepresentable {
    let controller: WebViewController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        mount(controller.webView, in: container)
        controller.loadIfNeeded()
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // If the hosted controller changed, swap the mounted web view.
        let current = container.subviews.first
        if current !== controller.webView {
            current?.removeFromSuperview()
            mount(controller.webView, in: container)
            controller.loadIfNeeded()
        }
    }

    private func mount(_ webView: WKWebView, in container: NSView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}
