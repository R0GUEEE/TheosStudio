import Foundation

/// A JSON value, so a tool schema or a parse of the model's arguments can be
/// built and checked without a schema definition library.
public indirect enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Numbers and strings that hold one. A model that sends `{"limit": 10}`
    /// means ten, and reading only `.stringValue` quietly returned the default
    /// instead — the kind of bug that looks like the model being ignored.
    public var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let text): return Int(text)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dictionary) = self { return dictionary[key] }
        return nil
    }

    /// A compact, deterministic rendering — used to show a tool call to the user
    /// and to keep tests readable.
    public func rendered() -> String {
        switch self {
        case .string(let value): return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let values): return "[" + values.map { $0.rendered() }.joined(separator: ",") + "]"
        case .object(let dictionary):
            let pairs = dictionary.keys.sorted().map { key in
                "\"" + key + "\":" + (dictionary[key]?.rendered() ?? "null")
            }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let dictionary): try container.encode(dictionary)
        case .null: try container.encodeNil()
        }
    }

    /// Convenience for building schemas.
    public static func schema(properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    public static func property(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }
}

public enum AgentRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

/// One function call the model asked for.
public struct AgentToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    /// The arguments exactly as the model produced them: a JSON string that may
    /// be malformed, which is why parsing them is a function with tests.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

extension AgentToolCall: Codable {
    private enum Wire: String, CodingKey {
        case id, type, function
    }
    private enum Function: String, CodingKey {
        case name, arguments
    }

    /// The OpenAI wire shape nests name and arguments under `function`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Wire.self)
        id = try container.decode(String.self, forKey: .id)
        let function = try container.nestedContainer(keyedBy: Function.self, forKey: .function)
        name = try function.decode(String.self, forKey: .name)
        arguments = try function.decodeIfPresent(String.self, forKey: .arguments) ?? "{}"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Wire.self)
        try container.encode(id, forKey: .id)
        try container.encode("function", forKey: .type)
        var function = container.nestedContainer(keyedBy: Function.self, forKey: .function)
        try function.encode(name, forKey: .name)
        try function.encode(arguments, forKey: .arguments)
    }
}

/// A message in the conversation, in the shape the Chat Completions API uses.
public struct AgentMessage: Equatable, Sendable {
    public var role: AgentRole
    public var content: String?
    public var toolCalls: [AgentToolCall]
    public var toolCallID: String?

    public init(role: AgentRole, content: String? = nil, toolCalls: [AgentToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public static func system(_ text: String) -> AgentMessage { .init(role: .system, content: text) }
    public static func user(_ text: String) -> AgentMessage { .init(role: .user, content: text) }
    public static func assistant(_ text: String) -> AgentMessage { .init(role: .assistant, content: text) }
    public static func toolResult(id: String, text: String) -> AgentMessage {
        .init(role: .tool, content: text, toolCallID: id)
    }
}

extension AgentMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case role, content, toolCalls = "tool_calls", toolCallID = "tool_call_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(AgentRole.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        toolCalls = try container.decodeIfPresent([AgentToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        // The API rejects an assistant message whose content is null only when it
        // has no tool calls; omitting the key entirely is what it expects.
        try container.encodeIfPresent(content, forKey: .content)
        if !toolCalls.isEmpty {
            try container.encode(toolCalls, forKey: .toolCalls)
        }
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }
}

/// One callable function, described the way the API wants it.
public struct AgentTool: Equatable, Sendable, Encodable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
    public var strict: Bool

    public init(name: String, description: String, parameters: JSONValue, strict: Bool = false) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }

    private enum CodingKeys: String, CodingKey {
        case type, function
    }
    private enum FunctionKeys: String, CodingKey {
        case name, description, parameters, strict
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("function", forKey: .type)
        var function = container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        try function.encode(name, forKey: .name)
        try function.encode(description, forKey: .description)
        try function.encode(parameters, forKey: .parameters)
    }
}

public struct AgentRequest: Encodable, Sendable {
    public var model: String
    public var messages: [AgentMessage]
    public var tools: [AgentTool]?
    public var toolChoice: String?
    public var temperature: Double?
    /// Worth setting on providers whose default is small: a tool call carrying a
    /// whole file can be cut off mid-argument, which looks like the model
    /// producing broken JSON rather than being truncated.
    public var maxTokens: Int?
    /// Merged into the request body verbatim, for parameters only one gateway
    /// understands (routing hints, reasoning budget, provider order). Written
    /// first, so the fields above always win over a typo in here.
    public var extraBody: [String: JSONValue]?
    /// Ask for the reply as it is written. A gateway that ignores it answers with
    /// a plain completion, which is read as one chunk.
    public var stream: Bool?

    public init(
        model: String,
        messages: [AgentMessage],
        tools: [AgentTool]? = nil,
        toolChoice: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        extraBody: [String: JSONValue]? = nil,
        stream: Bool? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.extraBody = extraBody
        self.stream = stream
    }

    /// One key type for everything: a keyed container is typed by its key, so a
    /// merged-in field whose name the schema does not know needs a dynamic key —
    /// and two key types cannot share one container, which is why the schema
    /// fields are written by name here too.
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)

        // Extras first: the typed fields below overwrite them, so a typo in there
        // cannot change the model or drop the conversation.
        for (key, value) in (extraBody ?? [:]).sorted(by: { $0.key < $1.key }) where !key.isEmpty {
            try container.encode(value, forKey: AnyKey(stringValue: key))
        }

        try container.encode(model, forKey: AnyKey(stringValue: "model"))
        try container.encode(messages, forKey: AnyKey(stringValue: "messages"))
        if let tools, !tools.isEmpty {
            try container.encode(tools, forKey: AnyKey(stringValue: "tools"))
            try container.encode(toolChoice ?? "auto", forKey: AnyKey(stringValue: "tool_choice"))
        }
        try container.encodeIfPresent(temperature, forKey: AnyKey(stringValue: "temperature"))
        if let maxTokens, maxTokens > 0 {
            try container.encode(maxTokens, forKey: AnyKey(stringValue: "max_tokens"))
        }
        if let stream {
            try container.encode(stream, forKey: AnyKey(stringValue: "stream"))
        }
    }
}

/// What the API sent back.
public struct AgentResponse: Decodable, Sendable {
    public struct Choice: Decodable, Sendable {
        public var message: AgentMessage
        public var finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    public struct APIError: Decodable, Sendable {
        public var message: String
        public var type: String?
    }

    public var choices: [Choice]
    public var error: APIError?

    /// The message to act on, if the response had one.
    public var message: AgentMessage? { choices.first?.message }

    public var toolCalls: [AgentToolCall] { message?.toolCalls ?? [] }
}
