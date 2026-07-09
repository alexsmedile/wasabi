import Foundation

/// Result of a license activation/validation call. On a successful *activation*,
/// `instanceID` carries the store's per-device instance handle (Lemon Squeezy
/// returns one from `/activate`); it's needed to validate/deactivate that device
/// later. `validate` results carry `nil` (the instance is already persisted).
enum LicenseStatus: Equatable {
    case valid(expiry: Date?, instanceID: String?)   // key is good; optional expiry + device instance
    case invalid(reason: String)                      // the store says this key is not valid
    case unreachable                                  // couldn't reach the store (network/offline)
}

/// The single seam between Wasabi and the store that issues license keys
/// (Lemon Squeezy — see DECISIONS.md). Swapping vendors later (e.g. Keygen) is a
/// new conformer, not a rewrite. This is deliberately the *only* abstraction in
/// the licensing layer — no factory, no config, no registry.
protocol LicenseBackend: Sendable {
    /// First-time bind of a key to this machine. On success the returned
    /// `.valid` carries the device `instanceID` to persist.
    func activate(key: String) async -> LicenseStatus
    /// Re-check an already-activated key (called in the background on launch).
    /// `instanceID` scopes the check to this device when the store supports it.
    func validate(key: String, instanceID: String?) async -> LicenseStatus
    /// Release this device's activation (from "Deactivate…"). Best-effort.
    func deactivate(key: String, instanceID: String?) async
}

#if WASABI_DEV
/// Offline stand-in used until a store account exists. Accepts any key matching
/// the demo format so the launch gate, Keychain storage, license window, and
/// offline-grace logic are all exercisable end-to-end today; the real HTTP
/// backend drops in behind the same protocol.
///
/// COMPILED OUT of release builds (#if WASABI_DEV) — a shipped binary contains
/// neither this stub nor the demo key it accepts. ponytail: stub, not fake-crypto.
/// Real vendor impl replaces its use in `LicenseManager` — see requests/licensing/PLAN.md.
struct StubLicenseBackend: LicenseBackend {
    /// A key "looks valid" if it's WASABI-XXXX-XXXX-XXXX (4-char groups). Enough
    /// to drive the UI/flow without pretending to be a real license server.
    static func looksValid(_ key: String) -> Bool {
        key.range(of: "^WASABI(-[A-Z0-9]{4}){3}$", options: .regularExpression) != nil
    }

    func activate(key: String) async -> LicenseStatus {
        Self.looksValid(key)
            ? .valid(expiry: nil, instanceID: "stub-instance")
            : .invalid(reason: "That doesn't look like a valid Wasabi license key.")
    }

    func validate(key: String, instanceID: String?) async -> LicenseStatus {
        // Offline stub: a previously-accepted key stays valid.
        Self.looksValid(key) ? .valid(expiry: nil, instanceID: nil) : .invalid(reason: "License key no longer valid.")
    }

    func deactivate(key: String, instanceID: String?) async { /* stub: nothing to release */ }
}
#endif
