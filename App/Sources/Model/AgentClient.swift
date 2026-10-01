import Foundation
import TheosStudioCore

/// Talks to an OpenAI-compatible chat completions endpoint.
///
/// One request shape is all that is needed: system prompt, conversation, tools,
/// and back comes either text or a set of function calls. Everything that decides
/// what to *do* with those calls lives elsewhere.
final class AgentClient {

    enum Failure: LocalizedError {
        case notConfigured
        case transport(String)
        case http(status: Int, body: String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "The assistant is not configured yet. Add a base URL, a model and an API key in Settings."
            case .transport(let message):
                return "Could not reach the API: \(message)"
            case .http(let status, let body):
                return "The API answered \(status). \(body.prefix(400))"
            case .malformed(let message):
                return "Could not read the API response: \(message)"
            }
        }
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    /// Sends the conversation and returns the assistant's reply.
    func send(
        messages: [AgentMessage],
        settings: AgentSettings,
        apiKey: String,
        tools: [AgentTool]
    ) async throws -> AgentMessage {
        guard settings.isConfigured, let endpoint = settings.endpoint else {
            throw Failure.notConfigured
        }

        let request = AgentRequest(
            model: settings.model,
            messages: messages,
            tools: tools,
            toolChoice: "auto",
            temperature: settings.temperature
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }

        let decoded: AgentResponse
        do {
            decoded = try JSONDecoder().decode(AgentResponse.self, from: data)
        } catch {
            throw Failure.malformed("\(error.localizedDescription) — \(String(decoding: data.prefix(200), as: UTF8.self))")
        }

        if let apiError = decoded.error {
            throw Failure.http(status: 200, body: apiError.message)
        }
        guard let message = decoded.message else {
            throw Failure.malformed("the response had no choices")
        }
        return message
    }

    /// A cheap way to check a key without spending a turn: ask for a one-line
    /// completion.
    func verify(settings: AgentSettings, apiKey: String) async throws -> String {
        let reply = try await send(
            messages: [
                .system("Reply with the single word: ready"),
                .user("Are you reachable?"),
            ],
            settings: settings,
            apiKey: apiKey,
            tools: []
        )
        return reply.content ?? "(empty reply)"
    }
}
