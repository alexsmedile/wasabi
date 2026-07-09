import Foundation

/// Maps each service id to a stable `WKWebsiteDataStore` UUID, persisted in
/// UserDefaults (`wasabi.datastore.<id>`) so the same service keeps its on-disk
/// session across launches.
///
/// The id→UUID mapping is **load-bearing**: it's the only link between a service
/// and its isolated store. `uuid(for:)` mints + persists on first read (so a
/// service "just works" the first time it's selected); the removal path uses
/// `peek(for:)` to read the existing mapping *without* minting, then `clear(for:)`
/// to delete the store + forget the mapping.
enum DataStoreID {
    private static func key(_ serviceID: String) -> String { "wasabi.datastore.\(serviceID)" }

    /// The service's data-store UUID, minting + persisting one on first access.
    static func uuid(for serviceID: String) -> UUID {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key(serviceID)), let uuid = UUID(uuidString: existing) {
            return uuid
        }
        let fresh = UUID()
        defaults.set(fresh.uuidString, forKey: key(serviceID))
        return fresh
    }

    /// The service's data-store UUID if one has already been minted, else nil.
    /// Used by the removal path so it doesn't accidentally mint a UUID for a store
    /// that was never created (a service the user added but never selected).
    static func peek(for serviceID: String) -> UUID? {
        guard let existing = UserDefaults.standard.string(forKey: key(serviceID)) else { return nil }
        return UUID(uuidString: existing)
    }

    /// Forget a service's id→UUID mapping (after its store has been deleted), so a
    /// later service reusing the same id can't bind to the removed store.
    static func clear(for serviceID: String) {
        UserDefaults.standard.removeObject(forKey: key(serviceID))
    }
}
