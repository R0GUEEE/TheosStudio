import Foundation
import Security
import TheosStudioCore

/// Where the assistant talks to, and what it has learned about each provider.
///
/// The endpoint and the chosen model are remembered *per provider*, so trying
/// DeepSeek and going back to OpenAI does not lose either one, and the setup
/// screen can fill itself in from the preset.
struct AgentSettings: Codable, Equatable {

    /// The endpoint and model last used for one provider.
    struct ProviderRuntime: Codable, Equatable {
        var baseURL: String = ""
        var model: String = ""
    }

    var providerID: String = AgentProvider.initial.id
    var baseURL: String = AgentProvider.initial.baseURL
    var model: String = ""
    var temperature: Double = 0.2
    /// Sent as a second system message on every request.
    var extraInstructions: String = ""
    /// How many tool executions one request may cause before the app stops it.
    var maxToolCallsPerTurn: Int = 12
    var runtimes: [String: ProviderRuntime] = [:]

    init() {}

    // MARK: - Derived

    var provider: AgentProvider { AgentProvider.provider(id: providerID) }

    private var trimmedBase: String {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// The chat-completions URL, tolerating a base URL that already ends in it.
    var endpoint: URL? {
        guard !trimmedBase.isEmpty else { return nil }
        if trimmedBase.hasSuffix("/chat/completions") { return URL(string: trimmedBase) }
        return URL(string: trimmedBase + "/chat/completions")
    }

    /// The model list URL, derived from the same base.
    var modelsEndpoint: URL? {
        guard !trimmedBase.isEmpty else { return nil }
        let base = trimmedBase.hasSuffix("/chat/completions")
            ? String(trimmedBase.dropLast("/chat/completions".count))
            : trimmedBase
        return URL(string: base + "/models")
    }

    var isConfigured: Bool {
        !trimmedBase.isEmpty && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The host to name in the "the key goes only here" line.
    var host: String {
        if let url = URL(string: trimmedBase), let host = url.host { return host }
        return provider.host
    }

    // MARK: - Switching providers

    /// Remembers where the current provider was left, then opens another one.
    mutating func select(_ next: AgentProvider) {
        rememberCurrent()
        providerID = next.id
        if let remembered = runtimes[next.id], !remembered.baseURL.isEmpty {
            baseURL = remembered.baseURL
            model = remembered.model
        } else {
            baseURL = next.baseURL
            // A provider that ships suggestions gets one filled in; the rest
            // leave it empty for the model picker to fill from the live list.
            model = next.suggestions.first ?? ""
        }
    }

    /// Called before switching away, and whenever the endpoint or model changes.
    mutating func rememberCurrent() {
        runtimes[providerID] = ProviderRuntime(baseURL: trimmedBase, model: model)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case providerID, baseURL, model, temperature, extraInstructions
        case maxToolCallsPerTurn, runtimes
    }

    /// Hand-written so that settings written by an older version still load: a
    /// missing key falls back to its default instead of throwing the whole file
    /// away, which would silently drop a user's provider choice.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            guard let decoded = try? container.decodeIfPresent(T.self, forKey: key) else { return fallback }
            return decoded ?? fallback
        }

        providerID = value(.providerID, AgentProvider.initial.id)
        baseURL = value(.baseURL, AgentProvider.initial.baseURL)
        model = value(.model, "")
        temperature = value(.temperature, 0.2)
        extraInstructions = value(.extraInstructions, "")
        maxToolCallsPerTurn = value(.maxToolCallsPerTurn, 12)
        runtimes = value(.runtimes, [:])
    }
}

/// API keys, one per provider, in the keychain.
///
/// Not in the settings file: a settings file is copied by backup tools and shown
/// by anything that can read the app's container, and this is the one value in the
/// app that is worth stealing. The account is scoped by provider so switching
/// providers does not overwrite the key you already typed.
enum AgentKeychain {

    private static let service = "com.r0gueee.theosstudio.agent"
    private static let legacyAccount = "api-key"

    private static func account(for providerID: String) -> String {
        "api-key." + providerID
    }

    // MARK: - Reading and writing

    static func save(_ key: String, for providerID: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            delete(for: providerID)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: providerID),
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Available to the app after the first unlock, and never copied to
            // another device by iCloud Keychain.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        // errSecItemNotFound (or anything else): try to add it.
        var insertion = query
        insertion.merge(attributes) { _, new in new }
        SecItemAdd(insertion as CFDictionary, nil)
    }

    static func load(for providerID: String) -> String? {
        if let key = read(account: account(for: providerID)) { return key }
        // Adopt a key saved by an earlier version, when there was only one.
        if let legacy = read(account: legacyAccount) {
            save(legacy, for: providerID)
            deleteAccount(legacyAccount)
            return legacy
        }
        return nil
    }

    static func delete(for providerID: String) {
        deleteAccount(account(for: providerID))
    }

    static func hasKey(for providerID: String) -> Bool {
        !(load(for: providerID) ?? "").isEmpty
    }

    // MARK: - Primitives

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    private static func deleteAccount(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
