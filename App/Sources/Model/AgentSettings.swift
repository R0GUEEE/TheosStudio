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
    /// What it may do without asking. The sandbox rules are not affected by this.
    var approvals: AgentApprovalPolicy = .askForChanges
    /// Standing instructions, as switches.
    var preferences: Set<AgentPreference> = []
    /// Which tools are offered at all.
    var enabledTools: Set<String> = AgentToolCatalog.names
    var contextMode: AgentContextMode = .fullFiles
    /// Characters of project content per request.
    var contextBudget: Int = 60_000
    /// Left at 0 to let the provider decide.
    var maxTokens: Int = 0
    /// Read the reply as it is written. Turn it off for a gateway that mishandles
    /// streaming.
    var streamsResponses: Bool = true
    /// Extra request fields, as JSON text.
    var extraBodyJSON: String = ""
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

    var contextModeOrDefault: AgentContextMode { contextMode }

    /// The parsed extra fields, or nil when there are none or they are not valid
    /// JSON — in which case the app sends the request without them rather than
    /// failing the turn.
    var decodedExtraBody: [String: JSONValue]? {
        let text = extraBodyJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        return object.isEmpty ? nil : object
    }

    var extraBodyIsValid: Bool {
        let text = extraBodyJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        return decodedExtraBody != nil
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
        case approvals, preferences, enabledTools, contextMode, contextBudget, maxTokens
        case streamsResponses, extraBodyJSON
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
        runtimes = value(.runtimes, [:])
        approvals = value(.approvals, .askForChanges)
        preferences = value(.preferences, [])
        enabledTools = value(.enabledTools, AgentToolCatalog.names)
        contextMode = value(.contextMode, .fullFiles)
        contextBudget = value(.contextBudget, 60_000)
        maxTokens = value(.maxTokens, 0)
        streamsResponses = value(.streamsResponses, true)
        extraBodyJSON = value(.extraBodyJSON, "")
    }
}

/// The API keys, one per provider.
///
/// The keychain is the right place for them, but an ad-hoc signed app can be
/// refused by securityd (`errSecMissingEntitlement`, -34018, unless the app
/// carries an application-identifier and a keychain-access-group). A store that
/// fails silently is worse than one that cannot store at all, so this keeps a
/// fallback in the app's own folder, reports which one it used, and never
/// pretends a key was saved when it was not.
enum AgentKeyStore {

    enum Storage: Equatable {
        case keychain
        /// Kept in the app's folder because the keychain refused it.
        case file(path: String, reason: String)
        case missing

        var label: String {
            switch self {
            case .keychain:
                return "Kept in the iOS keychain."
            case .file(_, let reason):
                return "Kept in the app's folder — \(reason)"
            case .missing:
                return "No key stored."
            }
        }

        var isSecure: Bool { self == .keychain }
    }

    private static let service = "com.r0gueee.theosstudio.agent"
    private static let legacyAccount = "api-key"

    // MARK: - Public

    @discardableResult
    static func save(_ key: String, for providerID: String) -> Storage {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(for: providerID)
            return .missing
        }

        let status = writeKeychain(trimmed, account: account(for: providerID))
        if status == errSecSuccess {
            // The keychain has it now; a file copy from an earlier attempt is
            // the thing to delete, not the thing to keep.
            try? FileManager.default.removeItem(atPath: fileURL(for: providerID).path)
            return .keychain
        }

        if writeFile(trimmed, for: providerID) != nil {
            return .file(path: fileURL(for: providerID).path, reason: describe(status))
        }
        return .missing
    }

    static func load(for providerID: String) -> String? {
        if let key = readKeychain(account: account(for: providerID)) {
            return key
        }
        // A key saved while the keychain was refusing us: use it, and move it
        // into the keychain if that works now.
        if let key = readFile(for: providerID) {
            if writeKeychain(key, account: account(for: providerID)) == errSecSuccess {
                try? FileManager.default.removeItem(atPath: fileURL(for: providerID).path)
            }
            return key
        }
        // A key saved by the version that had a single slot for all providers.
        if let legacy = readKeychain(account: legacyAccount) {
            save(legacy, for: providerID)
            deleteKeychain(account: legacyAccount)
            return legacy
        }
        return nil
    }

    static func storage(for providerID: String) -> Storage {
        if readKeychain(account: account(for: providerID)) != nil { return .keychain }
        if let key = readFile(for: providerID), !key.isEmpty {
            let status = writeKeychain(key, account: account(for: providerID))
            if status == errSecSuccess {
                try? FileManager.default.removeItem(atPath: fileURL(for: providerID).path)
                return .keychain
            }
            return .file(path: fileURL(for: providerID).path, reason: describe(status))
        }
        return .missing
    }

    static func hasKey(for providerID: String) -> Bool {
        load(for: providerID) != nil
    }

    static func delete(for providerID: String) {
        deleteKeychain(account: account(for: providerID))
        try? FileManager.default.removeItem(atPath: fileURL(for: providerID).path)
    }

    // MARK: - Keychain

    private static func account(for providerID: String) -> String {
        "api-key." + providerID
    }

    private static func writeKeychain(_ key: String, account: String) -> OSStatus {
        guard let data = key.data(using: .utf8) else { return errSecParam }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Update first: delete-then-add leaves a window where a conflict can stop
        // the new key from being stored at all.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return errSecSuccess }
        if updated != errSecItemNotFound { return updated }

        var insertion = query
        insertion.merge(attributes) { _, new in new }
        return SecItemAdd(insertion as CFDictionary, nil)
    }

    private static func readKeychain(account: String) -> String? {
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

    private static func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - File fallback

    /// A hidden directory in the app's own container, written 0600.
    private static func fileURL(for providerID: String) -> URL {
        let directory = URL(fileURLWithPath: Paths.documents).appendingPathComponent(".theosstudio/keys")
        let name = providerID.replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent(name)
    }

    private static func writeFile(_ key: String, for providerID: String) -> String? {
        let url = fileURL(for: providerID)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try key.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url.path
        } catch {
            return nil
        }
    }

    private static func readFile(for providerID: String) -> String? {
        let path = fileURL(for: providerID).path
        guard let key = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func describe(_ status: OSStatus) -> String {
        let code = Int(status)
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(code)"
        switch code {
        case -34018:
            return "the keychain refused this app (missing entitlement, \(code))"
        default:
            return "\(message) (\(code))"
        }
    }
}
