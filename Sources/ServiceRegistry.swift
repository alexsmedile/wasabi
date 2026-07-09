import Foundation

/// The persisted, mutable source of truth for the user's service list.
///
/// Wasabi started with a hardcoded `Service.defaults` snapshot; the registry
/// turns that into a **seed-then-own** model: on first launch it seeds the store
/// from `Service.defaults` (WhatsApp + Telegram), and from then on the persisted
/// JSON list is authoritative. Built-ins become ordinary entries the user can
/// reorder, rename, or remove. `Service.defaults` is never re-read once the store
/// exists.
///
/// Persistence is a JSON-encoded `[Service]` under `UserDefaults` key
/// `wasabi.services.v1`. The seed runs only when that key is absent, so once
/// persisted (even to an empty list) a user who removes every service doesn't get
/// them re-seeded on the next launch.
///
/// Per-service *policy* persistence stays in `WebViewPool`
/// (`wasabi.sleeppolicy.<id>`) — the registry does not duplicate it. A new
/// service is created with `sleepPolicy = .smartSleep` and the pool's unknown-id
/// fallback agrees, so both paths default to Smart.
@MainActor
final class ServiceRegistry {
    static let shared = ServiceRegistry()

    private static let storeKey = "wasabi.services.v1"

    /// Posted (on the main actor) after any mutation that changes the list.
    /// `MainViewController` subscribes to diff the registry against its live
    /// controllers/sidebar/pool and apply the delta.
    var onChange: (() -> Void)?

    private var services: [Service]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let loaded = Self.load(from: defaults) {
            services = loaded
        } else {
            // First launch (or a store we can't decode): seed from the built-ins.
            // Once persisted, `load` returns non-nil so the seed never re-runs.
            services = Service.defaults
            Self.persist(services, to: defaults)
        }
    }

    // MARK: - Read

    func all() -> [Service] { services }

    func service(id: String) -> Service? {
        services.first { $0.id == id }
    }

    // MARK: - Mutations (each persists + signals)

    /// Add a user service. The id is a **fresh UUID string minted once here** and
    /// never derived from the URL/name — renaming or editing the URL must not
    /// change the id, or the per-service data store and policy key would orphan.
    /// New services default to Smart Sleep and a neutral `globe` placeholder until
    /// the favicon resolves.
    @discardableResult
    func add(name: String, url: URL) -> Service {
        let service = Service(
            id: UUID().uuidString,
            name: Self.displayName(name, for: url),
            url: url,
            symbol: "globe",
            sleepPolicy: .smartSleep
        )
        services.append(service)
        commit()
        return service
    }

    /// The name to show for a service: the user's name if non-empty, else the
    /// URL's host (or the full URL as a last resort). One place so add + rename
    /// can't drift on what an empty name falls back to.
    static func displayName(_ name: String, for url: URL) -> String {
        name.isEmpty ? (url.host ?? url.absoluteString) : name
    }

    func remove(id: String) {
        guard services.contains(where: { $0.id == id }) else { return }
        services.removeAll { $0.id == id }
        commit()
    }

    func rename(id: String, to name: String) {
        guard let i = index(of: id) else { return }
        services[i].name = name
        commit()
    }

    /// Edit the URL while keeping the same id (so the session + policy survive; a
    /// changed host re-resolves the favicon naturally on next load).
    func setURL(id: String, to url: URL) {
        guard let i = index(of: id) else { return }
        services[i].url = url
        commit()
    }

    /// Edit name + URL together in one commit (the sidebar's "Edit…" path). Doing
    /// both in a single mutation avoids a double persist + double `onChange` reload
    /// and the transient {new name, old URL} state a two-call sequence would apply.
    func update(id: String, name: String, url: URL) {
        guard let i = index(of: id) else { return }
        services[i].name = name
        services[i].url = url
        commit()
    }

    /// Set the full order from an ordered list of ids (ids not present are kept in
    /// their current relative order at the end; unknown ids are ignored).
    func setOrder(_ ids: [String]) {
        var byID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        var reordered: [Service] = []
        for id in ids {
            if let s = byID.removeValue(forKey: id) { reordered.append(s) }
        }
        // Append any leftovers in their original order.
        for s in services where byID[s.id] != nil { reordered.append(s) }
        guard reordered.count == services.count else { return }
        services = reordered
        commit()
    }

    // MARK: - Internals

    private func index(of id: String) -> Int? {
        services.firstIndex { $0.id == id }
    }

    private func commit() {
        Self.persist(services, to: defaults)
        onChange?()
    }

    private static func load(from defaults: UserDefaults) -> [Service]? {
        guard let data = defaults.data(forKey: storeKey) else { return nil }
        return try? JSONDecoder().decode([Service].self, from: data)
    }

    private static func persist(_ services: [Service], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(services) else { return }
        defaults.set(data, forKey: storeKey)
    }
}
