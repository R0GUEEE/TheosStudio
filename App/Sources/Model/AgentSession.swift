import Foundation
import SwiftUI
import TheosStudioCore

/// Everything the assistant is allowed to touch, as closures.
///
/// The assistant gets a project, not a device: it can read and write files inside
/// one directory, run that project's build, and install what the build produced.
/// Everything else is out of reach by construction, which is a stronger guarantee
/// than a prompt that asks nicely.
@MainActor
struct AgentEnvironment {
    var projectPath: String
    var listFiles: () -> [ProjectEntry]
    var readFile: (String) -> String?
    var writeFile: (String, String) throws -> Void
    var loadControl: () -> ControlFile
    var saveControl: (ControlFile) throws -> Void
    // Annotated @MainActor because the closures these hold are written in the
    // view and touch its state; without the annotation the compiler has to guess.
    var build: @MainActor (Bool, Bool) async -> BuildRunner.Outcome
    var install: @MainActor () async -> (Bool, String)
    var privilegesCanEscalate: Bool
    var toolchainSummary: String?

    /// A snapshot of the project for the model: the text files, the manifest and
    /// what the device can do.
    func snapshot(buildSummary: String?) -> AgentProjectSnapshot {
        var files: [ProjectFile] = []
        for entry in listFiles() where !entry.isDirectory && entry.isProbablyText {
            // Nothing useful to a model lives in a megabyte, and reading every
            // file on every request would be felt on a phone.
            guard entry.size < 96 * 1024 else { continue }
            guard let contents = readFile(entry.relativePath) else { continue }
            files.append(ProjectFile(path: entry.relativePath, contents: contents))
        }

        let manifest = ProjectManifest.parse(
            makefile: readFile("Makefile") ?? "",
            control: readFile("control") ?? ""
        )
        return AgentProjectSnapshot(
            name: manifest.name ?? (projectPath as NSString).lastPathComponent,
            path: projectPath,
            kind: manifest.kind,
            scheme: manifest.declaredScheme ?? .rootless,
            packageIdentifier: manifest.packageIdentifier,
            version: manifest.version,
            files: files,
            buildSummary: buildSummary,
            toolchainSummary: toolchainSummary
        )
    }

    func absolute(_ relative: String) -> String {
        (projectPath as NSString).appendingPathComponent(relative)
    }
}

/// Turns an action into either an answer or a change waiting for approval.
///
/// The reason this is a separate step from executing: a `replace_in_file` whose
/// `find` does not match can be answered immediately with an explanation, and
/// never becomes an approval prompt the user would have to refuse.
@MainActor
enum AgentExecutor {

    struct Plan {
        var diff: String?
        var execute: @MainActor () async -> String
    }

    enum Preparation {
        case immediate(String)
        case approval(Plan)
    }

    static func prepare(_ action: AgentAction, in environment: AgentEnvironment) -> Preparation {
        switch action {
        case .listFiles:
            let entries = environment.listFiles()
            guard !entries.isEmpty else { return .immediate("The project directory is empty.") }
            let listing = entries.map { entry -> String in
                let kind = entry.isDirectory ? "dir " : "file"
                return "\(kind) \(entry.relativePath)\(entry.isDirectory ? "" : " (\(entry.size) bytes)")"
            }
            return .immediate(listing.joined(separator: "\n"))

        case .readFile(let path):
            guard let contents = environment.readFile(path) else {
                return .immediate("Error: there is no file at '\(path)'. Call list_files to see what exists.")
            }
            return .immediate(contents)

        case .writeFile(let path, let contents):
            let previous = environment.readFile(path) ?? ""
            guard previous != contents else {
                return .immediate("No change: \(path) already has exactly those contents.")
            }
            let diff = UnifiedDiff.render(from: previous, to: contents, path: path)
            return .approval(Plan(diff: diff) {
                do {
                    try environment.writeFile(path, contents)
                } catch {
                    return "Error: could not write \(path): \(error.localizedDescription)"
                }
                let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).count
                return "Wrote \(contents.utf8.count) bytes (\(lines) lines) to \(path)."
            })

        case .replaceInFile(let path, let find, let replace):
            guard let previous = environment.readFile(path) else {
                return .immediate("Error: there is no file at '\(path)'. Call list_files to see what exists.")
            }
            let occurrences = previous.components(separatedBy: find).count - 1
            if occurrences == 0 {
                return .immediate("Error: that text does not appear in \(path). Read the file and copy the exact text, including indentation.")
            }
            if occurrences > 1 {
                return .immediate("Error: that text appears \(occurrences) times in \(path). Include more surrounding context so the edit is unambiguous.")
            }
            let updated = previous.replacingOccurrences(of: find, with: replace)
            let diff = UnifiedDiff.render(from: previous, to: updated, path: path)
            return .approval(Plan(diff: diff) {
                do {
                    try environment.writeFile(path, updated)
                } catch {
                    return "Error: could not write \(path): \(error.localizedDescription)"
                }
                return "Edited \(path)."
            })

        case .updateControl(let key, let value):
            let previous = environment.readFile("control") ?? ""
            var control = environment.loadControl()
            control[key] = value
            let updated = control.serialized()
            guard previous.normalisedLineEndings() != updated else {
                return .immediate("No change: control already has that value for \(key).")
            }
            let diff = UnifiedDiff.render(from: previous, to: updated, path: "control")
            return .approval(Plan(diff: diff) {
                do {
                    try environment.saveControl(control)
                } catch {
                    return "Error: could not write control: \(error.localizedDescription)"
                }
                return value == nil ? "Removed \(key) from control." : "Set \(key) in control."
            })

        case .build(let clean, let final):
            return .approval(Plan(diff: nil) {
                let outcome = await environment.build(clean, final)
                return describe(outcome)
            })

        case .install:
            return .approval(Plan(diff: nil) {
                let (ok, message) = await environment.install()
                return ok ? message : "Error: \(message)"
            })

        case .finish(let summary):
            return .immediate("Turn finished: \(summary)")

        case .unknown(_, let reason):
            return .immediate("Error: \(reason)")
        }
    }

    /// What the model is told a build did. The diagnostics matter more than the
    /// exit status: they are the difference between "it failed" and "Tweak.x:12
    /// uses an undeclared identifier".
    static func describe(_ outcome: BuildRunner.Outcome) -> String {
        var lines: [String] = []
        if outcome.succeeded {
            lines.append("Build succeeded.")
            if let artifact = outcome.artifact {
                lines.append("Package: \((artifact as NSString).lastPathComponent)")
            } else {
                lines.append("No .deb was produced — check the console.")
            }
        } else {
            lines.append("Build failed (exit \(outcome.status)).")
        }

        let diagnostics = outcome.diagnostics
        if diagnostics.isEmpty {
            lines.append(outcome.succeeded
                ? "No warnings."
                : "No compiler diagnostics were produced, so the failure came from the build system itself rather than from the source.")
        } else {
            let errors = diagnostics.filter { $0.severity == .error }.count
            let warnings = diagnostics.filter { $0.severity == .warning }.count
            lines.append("\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s").")
            for diagnostic in diagnostics.prefix(30) {
                let location = diagnostic.location.map { "\($0): " } ?? ""
                lines.append("\(location)\(diagnostic.severity.rawValue): \(diagnostic.message)")
            }
            if diagnostics.count > 30 {
                lines.append("… \(diagnostics.count - 30) more.")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// One conversation with the assistant, including the approvals it stops at.
@MainActor
final class AgentSession: ObservableObject {

    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case user
            case assistant
            case tool
            case result
            case approval
            case note
            case error
        }

        let id = UUID()
        var kind: Kind
        var title: String? = nil
        var text: String = ""
    }

    struct Approval: Identifiable, Equatable {
        let id: UUID
        var summary: String
        var reason: String
        var diff: String?
    }

    enum Phase: Equatable {
        case idle
        case thinking
        case awaitingApproval
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .thinking, .awaitingApproval: return true
            case .idle, .failed: return false
            }
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pendingApproval: Approval?

    private let client = AgentClient()
    private var history: [AgentMessage] = []
    private var settings = AgentSettings()
    private var apiKey = ""
    private var environment: AgentEnvironment?
    private var batch: [AgentToolCall] = []
    private var awaiting: (call: AgentToolCall, action: AgentAction, plan: AgentExecutor.Plan)?
    private var toolExecutions = 0
    private var lastBuildSummary: String?
    private var task: Task<Void, Never>?

    /// A local endpoint (Ollama, LM Studio) needs no key, so "no key" is only a
    /// problem for a provider that asks for one.
    var isConfigured: Bool {
        settings.isConfigured && (!settings.provider.requiresKey || !apiKey.isEmpty)
    }

    func configure(settings: AgentSettings, apiKey: String) {
        self.settings = settings
        self.apiKey = apiKey
    }

    func reset() {
        task?.cancel()
        entries = []
        history = []
        batch = []
        awaiting = nil
        pendingApproval = nil
        lastBuildSummary = nil
        phase = .idle
    }

    // MARK: - Driving the turn

    func send(_ text: String, environment: AgentEnvironment) {
        guard !phase.isBusy else { return }
        self.environment = environment
        entries.append(Entry(kind: .user, text: text))
        history.append(.user(text))
        toolExecutions = 0
        task = Task { await advance() }
    }

    func stop() {
        task?.cancel()
        task = nil
        batch = []
        awaiting = nil
        pendingApproval = nil
        phase = .idle
        entries.append(Entry(kind: .note, text: "Stopped."))
    }

    func approve() {
        guard let pending = awaiting else { return }
        awaiting = nil
        pendingApproval = nil
        entries.append(Entry(
            kind: .approval,
            title: "Approved — \(pending.action.summary)",
            text: pending.plan.diff ?? ""
        ))
        task = Task {
            let result = await pending.plan.execute()
            record(result, for: pending.call, action: pending.action)
            await continueBatch()
        }
    }

    func deny() {
        guard let pending = awaiting else { return }
        awaiting = nil
        pendingApproval = nil
        entries.append(Entry(kind: .note, text: "Denied — \(pending.action.summary)"))
        history.append(.toolResult(
            id: pending.call.id,
            text: "Error: the user refused this action. Do not repeat it; ask what they would prefer."
        ))
        task = Task { await continueBatch() }
    }

    private func continueBatch() async {
        if await processBatch() {
            phase = .idle
        } else if awaiting == nil {
            await advance()
        }
    }

    /// One round trip: send the conversation, then handle everything the model
    /// asked for. Returns true when the turn is over.
    private func advance() async {
        guard let environment else { return }
        while !Task.isCancelled {
            phase = .thinking
            do {
                let reply = try await client.send(
                    messages: buildMessages(),
                    settings: settings,
                    apiKey: apiKey,
                    tools: AgentToolCatalog.all
                )
                history.append(reply)

                if let content = reply.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
                    entries.append(Entry(kind: .assistant, text: content))
                }

                guard !reply.toolCalls.isEmpty else {
                    phase = .idle
                    return
                }
                batch = reply.toolCalls
                if await processBatch() {
                    phase = .idle
                } else if awaiting == nil {
                    continue
                } else {
                    return
                }
            } catch {
                if Task.isCancelled { phase = .idle; return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                entries.append(Entry(kind: .error, text: message))
                phase = .failed(message)
                return
            }
        }
        _ = environment
    }

    /// Handles the queued tool calls. Returns true when the turn should end.
    private func processBatch() async -> Bool {
        guard let environment else { return true }
        while !batch.isEmpty {
            guard toolExecutions < max(1, settings.maxToolCallsPerTurn) else {
                entries.append(Entry(
                    kind: .note,
                    text: "Stopped after \(settings.maxToolCallsPerTurn) tool calls in one turn. Ask again to continue."
                ))
                batch = []
                return true
            }

            let call = batch.removeFirst()
            toolExecutions += 1
            let action = AgentActionParser.parse(call)

            if case .finish(let summary) = action {
                entries.append(Entry(kind: .assistant, text: summary))
                history.append(.toolResult(id: call.id, text: "Acknowledged."))
                batch = []
                return true
            }

            entries.append(Entry(kind: .tool, title: action.summary, text: call.name))

            switch AgentPolicy.decide(action, privilegesCanEscalate: environment.privilegesCanEscalate) {
            case .refused(let reason):
                entries.append(Entry(kind: .note, text: reason))
                history.append(.toolResult(id: call.id, text: "Error: \(reason)"))

            case .allowed, .needsApproval:
                switch AgentExecutor.prepare(action, in: environment) {
                case .immediate(let text):
                    // Nothing will change, so there is nothing to approve — even
                    // for an action the policy would otherwise gate.
                    record(text, for: call, action: action)

                case .approval(let plan):
                    if case .needsApproval(let reason) = AgentPolicy.decide(action, privilegesCanEscalate: environment.privilegesCanEscalate) {
                        awaiting = (call, action, plan)
                        pendingApproval = Approval(
                            id: UUID(),
                            summary: action.summary,
                            reason: reason,
                            diff: plan.diff
                        )
                        phase = .awaitingApproval
                        return false
                    }
                    let result = await plan.execute()
                    record(result, for: call, action: action)
                }
            }
        }
        return false
    }

    private func record(_ text: String, for call: AgentToolCall, action: AgentAction) {
        history.append(.toolResult(id: call.id, text: text))
        if case .build = action {
            lastBuildSummary = text
        }
        entries.append(Entry(kind: .result, title: action.summary, text: text))
    }

    private func buildMessages() -> [AgentMessage] {
        var messages: [AgentMessage] = []
        if let snapshot = environment?.snapshot(buildSummary: lastBuildSummary) {
            messages.append(.system(AgentContext.systemPrompt(snapshot)))
            if !settings.extraInstructions.trimmingCharacters(in: .whitespaces).isEmpty {
                messages.append(.system(settings.extraInstructions))
            }
            // The project is re-read on every request, so an edit the user made
            // by hand between two turns is in front of the model immediately.
            messages.append(.user(AgentContext.contextMessage(snapshot, budget: 40_000)))
        }
        messages.append(contentsOf: history)
        return messages
    }
}
