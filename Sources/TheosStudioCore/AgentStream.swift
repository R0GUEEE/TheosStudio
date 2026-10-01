import Foundation

/// What one line of a streaming response carried.
public enum AgentStreamEvent: Equatable, Sendable {
    /// A piece of the reply's text.
    case text(String)
    /// A piece of one tool call. `arguments` arrives in fragments and is
    /// reassembled by index.
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String)
    case finished(reason: String?)
    case failed(String)
}

/// Reassembles a streamed chat completion.
///
/// Streaming is worth the trouble for one reason: a turn on a phone with a
/// reasoning model can take half a minute, and half a minute of spinner is the
/// difference between "working" and "hung". The events arrive as server-sent
/// events — `data: {…}` lines — and a tool call is spread across several of them,
/// with the arguments arriving as string fragments that have to be concatenated
/// in index order.
public struct AgentStreamDecoder {

    private var content = ""
    private var toolCalls: [Int: (id: String?, name: String?, arguments: String)] = [:]
    private var finishReason: String?
    private var sawStreaming = false

    public init() {}

    /// True once any `data:` line has been seen — a gateway that ignores
    /// `stream: true` sends a plain response, which is read as one event.
    public var isStreaming: Bool { sawStreaming }

    public mutating func consume(line rawLine: String) -> [AgentStreamEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return [] }

        // SSE framing: comments start with a colon, and the fields we do not use
        // (`event:`, `id:`, `retry:`) are ignored.
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return [.finished(reason: finishReason)]
        }
        return consume(payload: payload)
    }

    /// One JSON chunk, with or without the `data:` prefix.
    mutating func consume(payload: String) -> [AgentStreamEvent] {
        guard let data = payload.data(using: .utf8) else { return [] }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else {
            // A malformed chunk is not worth failing a turn over; the assembled
            // message is checked for emptiness at the end.
            return []
        }
        sawStreaming = true

        if let error = chunk.error {
            return [.failed(error.message)]
        }
        guard let choice = chunk.choices?.first else { return [] }
        if let reason = choice.finish_reason {
            finishReason = reason
        }

        var events: [AgentStreamEvent] = []

        // The non-streaming shape, sent by gateways that ignore `stream: true`.
        if let message = choice.message {
            if let text = message.content, !text.isEmpty {
                content += text
                events.append(.text(text))
            }
            for (index, call) in message.toolCalls.enumerated() {
                absorb(index: index, id: call.id, name: call.name, arguments: call.arguments)
                events.append(.toolCallDelta(index: index, id: call.id, name: call.name, arguments: call.arguments))
            }
            if choice.finish_reason != nil {
                events.append(.finished(reason: finishReason))
            }
            return events
        }

        guard let delta = choice.delta else {
            if choice.finish_reason != nil { return [.finished(reason: finishReason)] }
            return []
        }

        if let text = delta.content, !text.isEmpty {
            content += text
            events.append(.text(text))
        }
        if let reasoning = delta.reasoning_content, !reasoning.isEmpty {
            // DeepSeek's reasoning models stream their thinking separately; it is
            // shown, but it is not part of the reply.
            events.append(.text(reasoning))
        }
        for call in delta.tool_calls ?? [] {
            let index = call.index ?? 0
            absorb(index: index, id: call.id, name: call.function?.name, arguments: call.function?.arguments ?? "")
            events.append(.toolCallDelta(
                index: index,
                id: call.id,
                name: call.function?.name,
                arguments: call.function?.arguments ?? ""
            ))
        }

        if choice.finish_reason != nil {
            events.append(.finished(reason: finishReason))
        }
        return events
    }

    /// Feeds a whole body: either a stream, or — for a gateway that ignored
    /// `stream: true` — one plain completion, which has no `data:` prefix at all.
    public mutating func consume(body: String) -> [AgentStreamEvent] {
        let text = body.normalisedLineEndings()
        guard text.contains("data:") else {
            return consume(payload: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { consume(line: String($0)) }
    }

    private mutating func absorb(index: Int, id: String?, name: String?, arguments: String) {
        var existing = toolCalls[index] ?? (nil, nil, "")
        if let id, !id.isEmpty { existing.id = id }
        if let name, !name.isEmpty {
            // A name arrives once, but a gateway may repeat it; keeping the first
            // complete one avoids `read_fileread_file`.
            existing.name = existing.name ?? name
        }
        existing.arguments += arguments
        toolCalls[index] = existing
    }

    /// The message the deltas add up to.
    public func message() -> AgentMessage {
        let calls = toolCalls.keys.sorted().map { index -> AgentToolCall in
            let entry = toolCalls[index]!
            return AgentToolCall(
                id: entry.id ?? "call_\(index)",
                name: entry.name ?? "",
                arguments: entry.arguments.isEmpty ? "{}" : entry.arguments
            )
        }
        return AgentMessage(
            role: .assistant,
            content: content.isEmpty ? nil : content,
            toolCalls: calls
        )
    }

    public var text: String { content }

    // MARK: - Wire

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                var content: String?
                var reasoning_content: String?
                var tool_calls: [ToolCallDelta]?
            }
            struct ToolCallDelta: Decodable {
                var index: Int?
                var id: String?
                var function: Function?
            }
            struct Function: Decodable {
                var name: String?
                var arguments: String?
            }
            var delta: Delta?
            var message: AgentMessage?
            var finish_reason: String?
        }
        struct Error: Decodable {
            var message: String
        }
        var choices: [Choice]?
        var error: Error?
    }
}
