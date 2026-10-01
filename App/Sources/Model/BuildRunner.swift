import Foundation
import SwiftUI
import TheosStudioCore

/// Runs `make` for a project and turns what it prints into something readable.
///
/// The runner is deliberately dumb about Theos: it asks the engine for a plan
/// (an argument vector and an environment), runs it, and separates the log into
/// the console and the diagnostics list. Everything that decides *what* to run
/// lives in the engine, where it is tested.
@MainActor
final class BuildRunner: ObservableObject {

    struct ConsoleLine: Identifiable, Equatable {
        enum Kind: Equatable { case command, output, notice }
        let id = UUID()
        var kind: Kind
        var text: String
    }

    enum Phase: Equatable {
        case idle
        case running(String)
        case succeeded
        case failed(Int32)
        case cancelled

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [ConsoleLine] = []
    @Published private(set) var diagnostics: [CompilerDiagnostic] = []
    @Published private(set) var artifact: String?
    /// The project the console is showing, so a stale console is never mistaken
    /// for the current project's output.
    @Published private(set) var projectPath: String?

    /// Called with the path of the `.deb` when a build finishes successfully.
    var onSucceeded: ((String) -> Void)?
    /// Called with the failure message when a build cannot even start.
    var onStartFailure: ((String) -> Void)?

    private var process: ShellProcess?
    private var queue: [BuildCommand] = []
    private var running: BuildCommand?
    private var lastStatus: Int32 = 0

    var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
    var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }

    var consoleText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    // MARK: - Starting

    func build(project: Project, store: StudioStore, cleanOnly: Bool = false) {
        guard !phase.isRunning else { return }

        lines = []
        diagnostics = []
        artifact = nil
        projectPath = project.path
        lastStatus = 0

        guard let toolchain = store.toolchain else {
            store.refreshToolchain()
            fail(StudioError.noToolchain)
            return
        }
        guard let make = toolchain.status(for: "make")?.path else {
            // A missing Theos is worth explaining before make gets the chance to
            // fail with something less specific.
            failMessage(toolchain.theosRoot == nil
                ? StudioError.noToolchain.localizedDescription
                : "make was not found on this device, so Theos cannot run. The Toolchain tab lists what is missing and the command that installs it.")
            return
        }

        let settings = store.settings
        let scheme = project.scheme ?? settings.effectiveScheme
        let request = BuildRequest(
            projectPath: project.path,
            scheme: scheme,
            finalPackage: cleanOnly ? false : settings.finalPackage,
            cleanFirst: !cleanOnly && settings.cleanBeforeBuild,
            verbose: settings.verboseBuild,
            jobs: settings.jobs > 1 ? settings.jobs : nil
        )
        var commands = BuildPlanner.plan(
            for: request,
            make: make,
            environment: store.buildEnvironment()
        )
        if cleanOnly {
            commands = Array(commands.suffix(1))
        }

        append(.init(kind: .notice, text: "\(scheme.displayName) build of \(project.name) — \(project.path)"))
        if !toolchain.isReadyToBuild {
            append(.init(kind: .notice, text: "Warning: this device is not fully set up (see the Toolchain tab). Trying anyway."))
        }

        queue = commands
        phase = .running(commands.first?.display ?? "make")
        runNext()
    }

    func cancel() {
        process?.terminate()
        append(.init(kind: .notice, text: "Cancelled. Theos may still be finishing the command it was in."))
        phase = .cancelled
        queue = []
        process = nil
    }

    func clear() {
        guard !phase.isRunning else { return }
        lines = []
        diagnostics = []
        artifact = nil
        phase = .idle
    }

    // MARK: - Running

    private func runNext() {
        // A cancelled build still gets the exit callback of whatever was running.
        if case .cancelled = phase { return }
        guard !queue.isEmpty else {
            finish(status: lastStatus)
            return
        }
        let command = queue.removeFirst()
        running = command
        append(.init(kind: .command, text: "→ \(command.display)"))

        let process = ShellProcess(
            executable: command.executable,
            arguments: command.arguments,
            environment: command.environment
        )
        self.process = process
        do {
            try process.run(onLine: { [weak self] line in
                self?.append(.init(kind: .output, text: line))
            }, onExit: { [weak self] outcome in
                guard let self else { return }
                self.process = nil
                self.lastStatus = outcome.status
                self.runNext()
            })
        } catch {
            append(.init(kind: .notice, text: error.localizedDescription))
            lastStatus = 127
            fail(error)
        }
    }

    private func finish(status: Int32) {
        running = nil
        guard let projectPath else {
            phase = status == 0 ? .succeeded : .failed(status)
            return
        }

        diagnostics = DiagnosticParser.diagnostics(in: lines.map(\.text))
        let reported = DiagnosticParser.packagedFile(in: lines.map(\.text))
        let found = ArtifactLocator.newestPackage(
            in: projectPath,
            listDirectory: FS.list,
            modificationDate: FS.modificationDate
        )
        // The path dpkg printed is relative to the project directory, and the
        // file on disk is what matters: prefer the search, and fall back to the
        // printed path only to explain where it went.
        artifact = found
        if let found {
            append(.init(kind: .notice, text: "Package: \(found)"))
        } else if let reported {
            append(.init(kind: .notice, text: "dpkg reported \(reported) but no .deb was found in packages/."))
        }

        if status == 0 {
            append(.init(kind: .notice, text: "Done."))
            phase = .succeeded
            if let found { onSucceeded?(found) }
        } else {
            let reason = DiagnosticParser.fatalLine(in: lines.map(\.text)) ?? "exit status \(status)"
            append(.init(kind: .notice, text: "Failed: \(reason)"))
            phase = .failed(status)
        }
    }

    private func fail(_ error: Error) {
        failMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private func failMessage(_ message: String) {
        append(.init(kind: .notice, text: message))
        diagnostics = []
        queue = []
        phase = .failed(127)
        onStartFailure?(message)
    }

    private func append(_ line: ConsoleLine) {
        // A build of a large project can print tens of thousands of lines; the
        // console keeps the tail, which is where the reason for a failure is.
        lines.append(line)
        if lines.count > 4000 {
            lines.removeFirst(lines.count - 4000)
        }
    }
}
