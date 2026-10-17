// Stem Eye -- what the app and its broadcast extension share: the settings (the app writes, the extension reads) and the
// extension's status (the other way). They live in the KEYCHAIN, in an access group both targets list in their entitlements
// (keychain-access-groups, team-prefixed: allowed by every provisioning profile, nothing to register on Apple's site -- unlike
// an App Group). New items land in the first group listed there, and a search covers all of them, so no group name is needed here.
// A build can also carry a default Controller address (Info.plist StemEyeController, from the CONTROLLER variable on GitHub).
import Foundation
import Security

struct Settings: Codable, Equatable {
    /// "192.168.1.20", "192.168.1.20:8080" or "http://pc.tail1234.ts.net:8080"
    var controller: String = ""
    /// -1 = automatic (ReplayKit's orientation tag), 0...3 = quarter turns clockwise that stand the picture up
    var rotation: Int = -1
    var maxFps: Double = 12
    /// learned by the extension: the automatic rotation was half a turn off (0 or 2)
    var flip: Int = 0

    private enum K: String, CodingKey { case controller, rotation, maxFps, flip }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        controller = (try? c.decodeIfPresent(String.self, forKey: .controller)) ?? ""
        rotation = (try? c.decodeIfPresent(Int.self, forKey: .rotation)) ?? -1
        maxFps = (try? c.decodeIfPresent(Double.self, forKey: .maxFps)) ?? 12
        flip = (try? c.decodeIfPresent(Int.self, forKey: .flip)) ?? 0
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(controller, forKey: .controller); try c.encode(rotation, forKey: .rotation)
        try c.encode(maxFps, forKey: .maxFps); try c.encode(flip, forKey: .flip)
    }
}

/// What the extension last did (the app shows it). Written every 2 s while broadcasting.
struct Status: Codable {
    var state = "idle"        // sending / connecting / no address / paused / stopped / error
    var detail = ""
    var fps = 0.0
    var kbps = 0.0
    var sent = 0
    var errors = 0
    var lastError = ""
    var rot = 0
    var rotFrom = ""          // tag / shape / manual (+ flipped)
    var live = false          // the Controller sees djay's decks
    var prog = ""
    var screen = ""           // "2732 x 2048"
    var buffer = ""           // "2048 x 2732 420f"
    var clock = ""            // pts / arrival
    var offMs: Double? = nil
    var rttMs: Double? = nil
    var controller = ""
    var at = 0.0              // seconds since 1970
}

enum Shared {
    static let service = "stemeye"

    // MARK: settings

    static func settings() -> Settings {
        var s = load(Settings.self, "settings") ?? Settings()
        if s.controller.trimmingCharacters(in: .whitespaces).isEmpty { s.controller = builtInController }
        return s
    }
    @discardableResult static func save(_ s: Settings) -> OSStatus { save(s, "settings") }

    /// the address baked into this build (may be empty)
    static var builtInController: String {
        let v = (Bundle.main.object(forInfoDictionaryKey: "StemEyeController") as? String) ?? ""
        return v.hasPrefix("$(") ? "" : v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: status

    static func status() -> Status? { load(Status.self, "status") }
    @discardableResult static func setStatus(_ s: Status) -> OSStatus {
        var v = s
        v.at = Date().timeIntervalSince1970
        return save(v, "status")
    }

    /// which keychain group the settings went to (shown in the app, to check the sharing works)
    static func settingsGroup() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "settings", kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let a = out as? [String: Any] else { return nil }
        return a[kSecAttrAccessGroup as String] as? String
    }

    // MARK: URL

    /// "192.168.1.20" / "192.168.1.20:8080" / "http://pc.tail1234.ts.net:8080" -> a base URL (http, port 8080 unless given)
    static func baseURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if let r = s.range(of: "/cc", options: [.backwards, .anchored]) { s.removeSubrange(r) }   // a pasted CC link
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        guard var c = URLComponents(string: s), let h = c.host, !h.isEmpty else { return nil }
        if c.port == nil && c.scheme?.lowercased() == "http" { c.port = 8080 }
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.url
    }

    // MARK: keychain

    static func load<T: Decodable>(_ type: T.Type, _ account: String) -> T? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    @discardableResult static func save<T: Encodable>(_ v: T, _ account: String) -> OSStatus {
        guard let d = try? JSONEncoder().encode(v) else { return errSecParam }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let upd: [String: Any] = [kSecValueData as String: d]
        var st = SecItemUpdate(q as CFDictionary, upd as CFDictionary)
        if st == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = d
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            st = SecItemAdd(add as CFDictionary, nil)
        }
        return st
    }
}
