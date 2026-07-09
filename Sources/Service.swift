import Foundation

/// A service is a pinned web app hosted in its own WKWebView + data store.
struct Service: Identifiable, Hashable, Codable {
    let id: String          // stable id; also used as the WKWebsiteDataStore key
    var name: String
    var url: URL
    var symbol: String      // SF Symbol name used as the sidebar icon (M1 placeholder for favicons)
    // keep live 5 min after focus loss, then sleep (overridden everywhere it's created)
    var sleepPolicy: SleepPolicy = .sleepAfterDefault
}

extension Service {
    /// M1 preconfigured services. WhatsApp Web + Telegram WebK client (/k/).
    /// See .spectacular/DECISIONS.md for the WebK-over-WebZ rationale.
    static let defaults: [Service] = [
        Service(
            id: "whatsapp",
            name: "WhatsApp",
            url: URL(string: "https://web.whatsapp.com")!,
            symbol: "message.fill",
            // Keep the two M1 services live so switching between them is instant
            // (no cold network reload). Their RAM cost is the accepted M1 tradeoff;
            // users can opt into Sleep/Smart per service from the right-click menu.
            sleepPolicy: .keepRunning
        ),
        Service(
            id: "telegram",
            name: "Telegram",
            url: URL(string: "https://web.telegram.org/k/")!,
            symbol: "paperplane.fill",
            sleepPolicy: .keepRunning
        ),
    ]
}
