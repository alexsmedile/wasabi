import Foundation

/// Product names, pricing, and entitlement copy shown inside Wasabi.
///
/// Keep launch messaging here so feature gates and the license
/// window do not drift into slightly different offers. Update `launchPrice`
/// when the introductory offer changes; checkout remains the source of truth.
enum ProductCopy {
    enum UpgradeContext {
        case general
        case dayOne
        case serviceLimit
        case smartSleep
        case reorder

        var headline: String {
            switch self {
            case .general: "Wasabi Pro"
            case .dayOne: "Meet Wasabi Pro"
            case .serviceLimit: "Unlock all your services"
            case .smartSleep: "This service was sleeping."
            case .reorder: "Put your services in order"
            }
        }

        var subtitle: String {
            switch self {
            case .general: "Wasabi is free for 2 services."
            case .dayOne: "Your 7-day trial is active. No card required."
            case .serviceLimit: "Wasabi Free includes 2 services. Pro removes the limit."
            case .smartSleep: "Smart Sleep wakes this periodically so messages are already here."
            case .reorder: "Drag to organize — keep your daily order at your fingertips."
            }
        }

        var isUnsolicited: Bool { self == .dayOne }
    }

    /// Show one price, not an ambiguous "EUR / USD" pair. The checkout remains
    /// authoritative; this only selects the matching launch copy for US locales.
    static var launchPrice: String {
        Locale.current.region?.identifier == "US" ? "$9.90" : "€9.90"
    }
    static var launchOffer: String { "Limited-time launch offer · \(launchPrice) once" }
    static let purchaseReassurance = "Yours forever. No subscription."

    /// Only advertise features that ship today. Custom icons have an entitlement
    /// placeholder in LicenseManager, but are intentionally absent until the UI exists.
    static let proFeatures = [
        "Unlimited services — WhatsApp, Telegram, Slack, as many as you need",
        "Smart Sleep — balances background freshness with memory savings",
        "Drag to reorder — keep your daily order",
    ]
    static let compactProFeatures = "✓ Unlimited services    ✓ Smart Sleep    ✓ Drag to reorder"

    static let trialEndedHeadline = "Your Pro trial ended"
    static let trialEndedSummary = "Wasabi is still free for 2 services. Your sessions are safe."
    static let servicesSafeNote = "The first two remain available."
}
