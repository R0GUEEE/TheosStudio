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

    public static func decode(_ data: Data) throws -> [AgentModel] {
        struct Response: Decodable {
            struct Item: Decodable {
                let id: String
                let name: String?
                let display_name: String?
                let context_length: Int?
            }
            let data: [Item]
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            // Some gateways return a bare array.
            if let items = try? JSONDecoder().decode([Response.Item].self, from: data) {
                return items.map { AgentModel(id: $0.id, displayName: $0.name ?? $0.display_name, contextLength: $0.context_length) }
            }
            throw error
        }
        return response.data.map {
            AgentModel(id: $0.id, displayName: $0.name ?? $0.display_name, contextLength: $0.context_length)
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

    /// The suggestions a provider ships, as full models.
    public static func suggestions(for provider: AgentProvider) -> [AgentModel] {
        provider.suggestions.map { AgentModel(id: $0) }
    }
}
