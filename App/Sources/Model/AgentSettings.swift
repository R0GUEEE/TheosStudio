import Foundation
import Security
import TheosStudioCore

/// Where the assistant talks to. Bring your own endpoint and key: the app has no
/// account, no proxy and no idea what a "provider" is beyond an
/// OpenAI-compatible `/chat/completions`.
struct AgentSettings: Codable, Equatable {
    /// e.g. `https://api.openai.com/v1`, a gateway, or a machine on the LAN.
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = "gpt-4o-mini"
    var temperature: Double = 0.2
    /// Sent as the first system message after the app's own prompt, for house
    /// style the user wants every turn to follow.
    var extraInstructions: String = ""
    /// How many tool executions a single request may cause before the app stops
    /// it. A model in a loop should not be able to build forever.
    var maxToolCallsPerTurn: Int = 12

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The chat-completions endpoint, tolerating a base URL with or without the
    /// `/v1` suffix and with a trailing slash.
    var endpoint: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/chat/completions") {
            return URL(string: base)
        }
        return URL(string: base + "/chat/completions")
    }
}

/// The API key lives in the keychain, not in the settings plist: it is the one
/// thing in this app that is worth stealing.
enum AgentKeychain {

    private static let service = "com.r0gueee.theosstudio.agent"

    static func save(_ key: String) {
        delete()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key",
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var hasKey: Bool { !(load() ?? "").isEmpty }
}
