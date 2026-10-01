import Foundation

/// A place the assistant can talk to.
///
/// The app has no account, so this is a menu of endpoints that speak the same
/// protocol, with the two facts a setup screen needs: where the API is, and
/// whether it wants a key. `suggestions` exists only for the case where the
/// provider's own model list cannot be fetched — the live list is always better,
/// which is why it is fetched whenever there is a key to fetch it with.
public struct AgentProvider: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let baseURL: String
    public let requiresKey: Bool
    /// Shown in the "the key is sent only to …" line.
    public let host: String
    public let suggestions: [String]
    public let documentation: String?
    public let note: String?

    public init(
        id: String,
        displayName: String,
        baseURL: String,
        requiresKey: Bool = true,
        host: String,
        suggestions: [String] = [],
        documentation: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.requiresKey = requiresKey
        self.host = host
        self.suggestions = suggestions
        self.documentation = documentation
        self.note = note
    }
}

extension AgentProvider {

    public static let customID = "custom"

    /// Ordered the way someone setting this up would read it: the two household
    /// names first, then the aggregators, then the local options.
    public static let all: [AgentProvider] = [
        AgentProvider(
            id: "openai",
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            host: "api.openai.com",
            documentation: "https://platform.openai.com/api-keys"
        ),
        AgentProvider(
            id: "deepseek",
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            host: "api.deepseek.com",
            suggestions: ["deepseek-chat", "deepseek-reasoner"],
            documentation: "https://platform.deepseek.com/api_keys",
            note: "deepseek-chat is the general model; deepseek-reasoner thinks before answering and costs more per turn."
        ),
        AgentProvider(
            id: "openrouter",
            displayName: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            host: "openrouter.ai",
            documentation: "https://openrouter.ai/keys",
            note: "One key for most models, including several free ones. The model list is public, so it loads without a key."
        ),
        AgentProvider(
            id: "anthropic",
            displayName: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            host: "api.anthropic.com",
            documentation: "https://console.anthropic.com/settings/keys",
            note: "Through Anthropic's OpenAI-compatible endpoint, so the wire format is the one this app speaks."
        ),
        AgentProvider(
            id: "gemini",
            displayName: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            host: "generativelanguage.googleapis.com",
            suggestions: ["gemini-2.5-pro", "gemini-2.5-flash"],
            documentation: "https://aistudio.google.com/apikey",
            note: "Gemini's OpenAI-compatible endpoint does not list models, so pick one of the suggestions or type the id."
        ),
        AgentProvider(
            id: "groq",
            displayName: "Groq",
            baseURL: "https://api.groq.com/openai/v1",
            host: "api.groq.com",
            documentation: "https://console.groq.com/keys",
            note: "Very fast, mostly open-weight models."
        ),
        AgentProvider(
            id: "mistral",
            displayName: "Mistral",
            baseURL: "https://api.mistral.ai/v1",
            host: "api.mistral.ai",
            documentation: "https://console.mistral.ai/api-keys"
        ),
        AgentProvider(
            id: "xai",
            displayName: "xAI",
            baseURL: "https://api.x.ai/v1",
            host: "api.x.ai",
            documentation: "https://console.x.ai"
        ),
        AgentProvider(
            id: "together",
            displayName: "Together",
            baseURL: "https://api.together.xyz/v1",
            host: "api.together.xyz",
            documentation: "https://api.together.ai/settings/api-keys"
        ),
        AgentProvider(
            id: "ollama",
            displayName: "Ollama (this device or LAN)",
            baseURL: "http://localhost:11434/v1",
            requiresKey: false,
            host: "localhost",
            documentation: "https://ollama.com",
            note: "Runs on your own machine. On a phone, point this at the IP of the computer running Ollama, e.g. http://192.168.1.10:11434/v1."
        ),
        AgentProvider(
            id: "lmstudio",
            displayName: "LM Studio (this device or LAN)",
            baseURL: "http://localhost:1234/v1",
            requiresKey: false,
            host: "localhost",
            documentation: "https://lmstudio.ai",
            note: "Start the local server in LM Studio, then use its address here."
        ),
        AgentProvider(
            id: customID,
            displayName: "Custom endpoint",
            baseURL: "",
            requiresKey: false,
            host: "your endpoint",
            note: "Any OpenAI-compatible /chat/completions endpoint, including a company gateway."
        ),
    ]

    /// The provider for an id, or the custom entry for anything unknown — an
    /// endpoint saved before its provider existed should still open.
    public static func provider(id: String?) -> AgentProvider {
        guard let id, let match = all.first(where: { $0.id == id }) else {
            return all.first { $0.id == customID } ?? all[0]
        }
        return match
    }

    public static var initial: AgentProvider { all[0] }

    public var isCustom: Bool { id == Self.customID }
}

/// One model, as the provider describes it.
public struct AgentModel: Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String?
    public var contextLength: Int?

    public init(id: String, displayName: String? = nil, contextLength: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.contextLength = contextLength
    }

    public var title: String { displayName ?? id }
}

/// Reads `GET /models`.
///
/// The response shape is the same everywhere that speaks OpenAI's protocol, but
/// the *contents* are not: a provider lists embeddings, speech and image models
/// in the same array, and offering `text-embedding-3-small` as a coding agent is
/// worse than offering nothing.
public enum AgentModelList {

    /// Substrings that mark an id as something other than a chat model.
    public static let nonChatMarkers: [String] = [
        "embed", "whisper", "tts", "dall-e", "moderation", "rerank", "image",
        "speech", "transcribe", "realtime", ":batch", "guard", "ocr", "clip",
        "stable-diffusion", "sora", "veo", "imagen",
    ]

    /// Reads whatever the provider sent.
    ///
    /// The protocol says `{"data": [{"id": …}]}`, and most providers comply.
    /// DeepSeek and others ship no name or context length; some gateways nest the
    /// array under `models`; a few local servers return a bare array. Failing to
    /// read a list that is *nearly* the right shape is the difference between a
    /// picker and a typed model name, so all of those are accepted, and an entry
    /// without any identifier is skipped rather than failing the whole response.
    public static func decode(_ data: Data) throws -> [AgentModel] {
        struct Item: Decodable {
            var identifier: String?
            var displayName: String?
            var contextLength: Int?

            private enum Keys: String, CodingKey {
                case id, model, name
                case displayName = "display_name"
                case contextLength = "context_length"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                identifier = (try? container.decodeIfPresent(String.self, forKey: .id))
                    ?? (try? container.decodeIfPresent(String.self, forKey: .model))
                    ?? nil
                displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName))
                    ?? (try? container.decodeIfPresent(String.self, forKey: .name))
                    ?? nil
                if let number = try? container.decodeIfPresent(Int.self, forKey: .contextLength) {
                    contextLength = number
                } else if let text = try? container.decodeIfPresent(String.self, forKey: .contextLength) {
                    // Some servers send the context window as a string.
                    contextLength = Int(text)
                } else {
                    contextLength = nil
                }
            }
        }

        struct DataKeyed: Decodable { let data: [Item] }
        struct ModelsKeyed: Decodable { let models: [Item] }

        var items: [Item]?
        if let response = try? JSONDecoder().decode(DataKeyed.self, from: data) {
            items = response.data
        } else if let response = try? JSONDecoder().decode(ModelsKeyed.self, from: data) {
            items = response.models
        } else if let bare = try? JSONDecoder().decode([Item].self, from: data) {
            items = bare
        }

        guard let items else {
            throw SDKFetchError.malformed
        }
        return items.compactMap { item in
            guard let identifier = item.identifier, !identifier.isEmpty else { return nil }
            return AgentModel(id: identifier, displayName: item.displayName, contextLength: item.contextLength)
        }
    }

    public static func isChatModel(_ model: AgentModel) -> Bool {
        let identifier = model.id.lowercased()
        return !nonChatMarkers.contains { identifier.contains($0) }
    }

    public static func chatModels(_ models: [AgentModel]) -> [AgentModel] {
        sorted(models.filter(isChatModel))
    }

    /// Alphabetical by id, case-insensitively, with duplicate ids collapsed —
    /// aggregators repeat models across providers.
    public static func sorted(_ models: [AgentModel]) -> [AgentModel] {
        var seen = Set<String>()
        var unique: [AgentModel] = []
        for model in models where seen.insert(model.id).inserted {
            unique.append(model)
        }
        return unique.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// What to say about a model the assistant should not be pointed at without
    /// knowing the cost.
    ///
    /// The assistant works by calling tools, and some models do not accept tool
    /// definitions at all — DeepSeek's own reasoning model is the well-known case,
    /// and it fails every turn rather than degrading. Saying so at the point of
    /// choosing beats an unexplained 400 later.
    public static func toolCallingCaveat(for modelID: String) -> String? {
        let identifier = modelID.lowercased()
        let looksReasoning = identifier.contains("deepseek-reasoner")
            || identifier.contains("reasoning")
            || identifier.contains("-r1")
            || identifier.hasSuffix("r1")
        guard looksReasoning else { return nil }
        return "Reasoning models do not all accept tool definitions, and the assistant needs them. If a turn fails with an error mentioning tools, switch to a general chat model — deepseek-chat, for instance."
    }

    /// The suggestions a provider ships, as full models.
    public static func suggestions(for provider: AgentProvider) -> [AgentModel] {
        provider.suggestions.map { AgentModel(id: $0) }
    }
}
