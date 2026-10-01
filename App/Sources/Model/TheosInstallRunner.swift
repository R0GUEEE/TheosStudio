import Foundation
import SwiftUI
import TheosStudioCore

/// Installs Theos on the device.
///
/// It runs the same steps the official installer does on a jailbroken device —
/// dependency packages from the package manager, then Theos itself and an SDK —
/// but with the split made explicit: only the packages need root. So on a device
/// where the app cannot become root, the SDK and Theos are still installed, and
/// the one part that could not run is named instead of the whole thing failing.
@MainActor
final class TheosInstallRunner: ObservableObject {

    enum Phase: Equatable {
        case idle
        case preparing
        case working(String)
        case finished(String)
        case failed(String)
        case cancelled

        var isRunning: Bool {
            switch self {
            case .preparing, .working: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log: [String] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var completedSteps = 0
    @Published private(set) var totalSteps = 0

    private var queue: [InstallStep] = []
    private var privileges = PrivilegeContext(mode: .unprivileged)
    private var toolPaths: [String: String] = [:]
    private var destination = ""
    private var scope: InstallScope = .theosAndSDK
    private var process: ShellProcess?
    /// Every command runs with the app's PATH repaired: without it `git` cannot
    /// find `git-remote-https` and `tar -xJf` cannot find `xz`.
    private var environment: [String: String] = [:]
    /// The store is only used to rescan the toolchain once the install is done.
    private weak var store: StudioStore?

    var progress: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(completedSteps) / Double(totalSteps)
    }

    // MARK: - Starting

    func start(store: StudioStore, destination: String, scope: InstallScope) {
        guard !phase.isRunning else { return }

        self.store = store
        self.destination = destination
        self.scope = scope
        self.privileges = store.privileges
        self.environment = store.commandEnvironment()
        self.log = []
        self.warnings = []
        self.completedSteps = 0
        self.totalSteps = 0
        self.queue = []

        let needed = ["git", "tar", "xz", "mkdir", "apt-get"]
        toolPaths = store.toolPaths(for: needed)

        append("$ destination: \(destination)")
        append("$ privileges: \(privileges.summary)")

        append("$ PATH: \(environment["PATH"] ?? "unset")")

        if scope == .dependenciesOnly {
            finishPlanning(store: store, asset: nil)
        } else {
            phase = .preparing
            append("Looking up the newest SDK in theos/sdks…")
            Task { await self.lookupSDK(store: store) }
        }
    }

    /// The SDK is a release asset, so its URL is only known after asking GitHub.
    /// A failure here is not fatal: Theos installs without an SDK, the plan says
    /// so, and the SDK can be fetched later by running this again.
    private func lookupSDK(store: StudioStore) async {
        var asset: SDKAsset?
        do {
            let (data, response) = try await URLSession.shared.data(from: TheosInstaller.sdkReleaseURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw SDKFetchError.noAssets
            }
            asset = try TheosInstaller.latestSDKAsset(fromReleaseJSON: data)
            if let asset {
                append("Newest SDK: \(asset.name)")
            }
        } catch {
            append("Could not read the SDK release list: \(error.localizedDescription)")
            append("Continuing without an SDK — the plan will say what that costs.")
        }
        finishPlanning(store: store, asset: asset)
    }

    private func finishPlanning(store: StudioStore, asset: SDKAsset?) {
        let options = TheosInstallOptions(
            destination: destination,
            scope: scope,
            sdkAsset: asset,
            procursus: store.isProcursus
        )
        let plan = TheosInstaller.plan(
            options: options,
            toolPaths: toolPaths,
            privileges: privileges,
            exists: FS.fileExists,
            listDirectory: FS.list
        )
        warnings = plan.warnings
        queue = plan.steps
        totalSteps = plan.steps.count

        guard !queue.isEmpty else {
            fail("Nothing can be installed: \(plan.warnings.first ?? "the plan is empty")")
            return
        }
        append("\(totalSteps) steps planned:")
        for (index, step) in plan.steps.enumerated() {
            append("  \(index + 1). \(step.label)")
        }
        runNext()
    }

    func cancel() {
        process?.terminate()
        queue = []
        phase = .cancelled
        append("Cancelled.")
    }

    // MARK: - Running

    private func runNext() {
        guard !queue.isEmpty else {
            finish()
            return
        }
        let step = queue.removeFirst()

        if let existing = step.skipIfExists, FS.fileExists(existing) {
            append("• \(step.label) — already there, skipping")
            completedSteps += 1
            runNext()
            return
        }

        if let note = step.note {
            append("  \(note)")
        }

        switch step.kind {
        case .download(let url, let destination):
            phase = .working(step.label)
            append("↓ \(step.label)")
            Task { await self.download(url, to: destination, step: step) }

        case .command(let tool, let arguments):
            guard let path = toolPaths[tool] else {
                fail("\(tool) is not installed, so “\(step.label)” cannot run.")
                return
            }
            let (executable, finalArguments) = step.requiresRoot
                ? privileges.wrapped(path, arguments)
                : (path, arguments)

            phase = .working(step.label)
            append("→ \(step.label): \(pretty(executable, finalArguments))")

            let process = ShellProcess(
                executable: executable,
                arguments: finalArguments,
                environment: environment
            )
            self.process = process
            do {
                try process.run(onLine: { [weak self] line in
                    self?.append(line)
                }, onExit: { [weak self] outcome in
                    guard let self else { return }
                    self.process = nil
                    if outcome.status == 0 {
                        self.completedSteps += 1
                        self.runNext()
                    } else if step.tolerateFailure {
                        // A rung of a fallback ladder: the next step is the retry.
                        self.append("  that did not work — trying the next step")
                        self.completedSteps += 1
                        self.runNext()
                    } else {
                        self.fail(self.failureMessage(
                            for: step,
                            outcome: outcome,
                            command: self.pretty(executable, finalArguments)
                        ))
                    }
                })
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Downloads a file with the app's own networking.
    ///
    /// This is what makes installing an SDK possible on a device with no `curl`:
    /// the app has a URLSession, so the only thing the plan needs from the device
    /// is `tar`.
    private func download(_ url: String, to destination: String, step: InstallStep) async {
        guard let remote = URL(string: url) else {
            fail("The SDK URL is not usable: \(url)")
            return
        }
        do {
            let (temporary, response) = try await URLSession.shared.download(from: remote)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                fail("The download failed with HTTP \(http.statusCode).")
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)??.intValue ?? 0
            try? FileManager.default.removeItem(atPath: destination)
            try FileManager.default.moveItem(atPath: temporary.path, toPath: destination)
            append("  downloaded \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
            completedSteps += 1
            runNext()
        } catch {
            fail("Could not download \(step.label): \(error.localizedDescription)")
        }
    }

    private func finish() {
        // Only now is this the Theos to use. Pointing at the destination before
        // the install ran leaves the app looking at a folder that may hold
        // nothing, which is exactly how "Theos found but no SDK" happens.
        store?.settings.theosPathOverride = destination
        store?.refreshToolchain()
        phase = .finished("Theos installed in \(destination).")
        append("Done. Theos is now used from \(destination).")
    }

    // MARK: - Reporting

    private func failureMessage(for step: InstallStep, outcome: ShellProcess.Outcome, command: String) -> String {
        let tail = outcome.output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? "no output"
        // The exact command is in the message on purpose: it is the thing that can
        // be pasted into a terminal to see the same failure with a shell's help.
        var message = "\(step.label) failed (exit \(outcome.status)): \(tail)\n\ncommand: \(command)"
        if step.requiresRoot && !privileges.canEscalate {
            // A download has no tool to name, so fall back to the step's label.
            let tool = step.tool ?? step.label
            let command = pretty(toolPaths[step.tool ?? ""] ?? tool, step.arguments)
            message += "\n\n" + privileges.remedy(for: command)
        }
        return message
    }

    private func fail(_ message: String) {
        append(message)
        phase = .failed(message)
    }

    private func pretty(_ executable: String, _ arguments: [String]) -> String {
        ShellQuote.join([executable] + arguments)
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 2000 {
            log.removeFirst(log.count - 2000)
        }
    }
}
