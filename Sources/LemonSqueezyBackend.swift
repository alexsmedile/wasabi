import Foundation

/// Production `LicenseBackend` backed by the Lemon Squeezy License API
/// (https://api.lemonsqueezy.com/v1/licenses/…). See DECISIONS.md.
///
/// **No secret ships.** The license endpoints authenticate with the user-pasted
/// license key itself — there is NO API key or Authorization header. (Your Lemon
/// Squeezy *store* API key is a separate admin secret and must never be embedded
/// in the app.) So this file contains nothing confidential.
///
/// Contract notes baked in below:
/// - Success flag differs per endpoint: `activated` / `valid` / `deactivated`.
///   The reliable signal is `error == nil` on a 2xx JSON body — an over-limit
///   activation returns HTTP 2xx with `activated: false` + an `error` string.
/// - `/activate` returns an `instance.id` we must persist for later validate/deactivate.
/// - Any transport/decode failure maps to `.unreachable` (NEVER `.invalid`), so a
///   network blip can't lock out a paying user (the manager's offline grace carries them).
struct LemonSqueezyBackend: LicenseBackend {
    private let base = URL(string: "https://api.lemonsqueezy.com/v1/licenses")!

    // MARK: - LicenseBackend

    func activate(key: String) async -> LicenseStatus {
        let form = ["license_key": key, "instance_name": Self.instanceName]
        guard let resp: Response = await post("activate", form) else { return .unreachable }
        guard resp.error == nil, resp.activated == true else {
            return .invalid(reason: resp.error ?? "This license key could not be activated.")
        }
        return .valid(expiry: resp.license_key?.expiryDate, instanceID: resp.instance?.id)
    }

    func validate(key: String, instanceID: String?) async -> LicenseStatus {
        var form = ["license_key": key]
        if let instanceID { form["instance_id"] = instanceID }
        guard let resp: Response = await post("validate", form) else { return .unreachable }
        // `disabled`/`expired` come back valid:false with an error; treat as invalid.
        guard resp.error == nil, resp.valid == true else {
            return .invalid(reason: resp.error ?? "This license key is no longer valid.")
        }
        return .valid(expiry: resp.license_key?.expiryDate, instanceID: nil)
    }

    func deactivate(key: String, instanceID: String?) async {
        guard let instanceID else { return }   // nothing to release without an instance
        _ = await post("deactivate", ["license_key": key, "instance_id": instanceID]) as Response?
    }

    // MARK: - HTTP

    /// A human label shown in the Lemon Squeezy dashboard for this activation.
    /// Host name keeps it recognizable without leaking anything sensitive.
    private static var instanceName: String {
        Host.current().localizedName ?? "Wasabi on macOS"
    }

    private func post(_ path: String, _ fields: [String: String]) async -> Response? {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields
            .map { "\($0.key)=\(Self.escape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        guard let (data, http) = try? await URLSession.shared.data(for: req),
              let code = (http as? HTTPURLResponse)?.statusCode else { return nil }
        // 2xx and 4xx both carry a decodable JSON body with `error`; 5xx/garbage → nil (unreachable).
        guard (200...499).contains(code),
              let resp = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return resp
    }

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    // MARK: - Response model (shared across all three endpoints)

    private struct Response: Decodable {
        let activated: Bool?      // /activate
        let valid: Bool?          // /validate
        let deactivated: Bool?    // /deactivate
        let error: String?
        let license_key: LicenseKey?
        let instance: Instance?

        struct LicenseKey: Decodable {
            let status: String
            let expires_at: String?
            var expiryDate: Date? { expires_at.flatMap { ISO8601DateFormatter().date(from: $0) } }
        }
        struct Instance: Decodable {
            let id: String
        }
    }
}
