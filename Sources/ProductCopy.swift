import Foundation

/// Product names, pricing, and entitlement copy shown inside Wasabi.
///
/// Keep launch messaging here so feature gates and the license
/// window do not drift into slightly different offers. Update `launchPrice`
/// when the introductory offer changes; checkout remains the source of truth.
enum ProductCopy {
    static let launchPrice = "€9.90 / $9.90"
    static let proHeadline = "Upgrade"
    static let proSummary = "Unlimited services, Smart Sleep, and drag to reorder."
    static let launchOffer = "Limited-time launch offer · \(launchPrice) · One-time purchase"

    /// Only advertise features that ship today. Custom icons have an entitlement
    /// placeholder in LicenseManager, but are intentionally absent until the UI exists.
    static let proFeatures = [
        "Unlimited services",
        "Smart Sleep",
        "Drag to reorder",
    ]

    static let serviceLimitReason = "Community includes up to 2 services."
}
