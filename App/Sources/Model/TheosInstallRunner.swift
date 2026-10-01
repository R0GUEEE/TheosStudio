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
    private var process: ShellProcess?
    /// The store is only used to rescan the toolchain once the install is done.
    private weak var store: StudioStore?

    var progress: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(completedSteps) / Double(totalSteps)
    }

    // MARK: - Starting

    func start(store: StudioStore, destination: String, installDependencies: Bool, fetchSDK: Bool) {
        guard !phase.isRunning else { return }

        self.store = store
        self.destination = destination
        self.privileges = store.privileges
        self.log = []
        self.warnings = []
        self.completedSteps = 0
        self.totalSteps = 0
        self.queue = []
        store.settings.theosPathOverride = destination

        let needed = ["git", "curl", "tar", "mkdir", "apt-get"]
        toolPaths = store.toolPaths(for: needed)

        append("$ destination: \(destination)")
        append("$ privileges: \(privileges.summary)")

        if fetchSDK {
            phase = .preparing
            append("Looking up the newest SDK in theos/sdks…")
            Task { await self.lookupSDK(store: store, installDependencies: installDependencies, fetchSDK: fetchSDK) }
        } else {
            finishPlanning(store: store, asset: nil, installDependencies: installDependencies, fetchSDK: fetchSDK)
        }
    }

    /// The SDK is a release asset, so its URL is only known after asking GitHub.
    /// A failure here is not fatal: Theos installs without an SDK, the plan says
    /// so, and the SDK can be fetched later by running this again.
    private func lookupSDK(store: StudioStore, installDependencies: Bool, fetchSDK: Bool) async {
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
        finishPlanning(store: store, asset: asset, installDependencies: installDependencies, fetchSDK: fetchSDK)
    }

    private func finishPlanning(store: StudioStore, asset: SDKAsset?, installDependencies: Bool, fetchSDK: Bool) {
        let options = TheosInstallOptions(
            destination: destination,
            installDependencies: installDependencies,
            fetchSDK: fetchSDK,
            sdkAsset: asset,
            procursus: store.isProcursus
        )
        let plan = TheosInstaller.plan(options: options, toolPaths: toolPaths, privileges: privileges)
        warnings = plan.warnings
        queue = plan.steps
        totalSteps = plan.steps.count

        guard !queue.isEmpty else {
            fail("Nothing can be installed: \(plan.warnings.first ?? "the plan is empty")")
            return
        }
        append("\(totalSteps) steps planned.")
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

        guard let tool = toolPaths[step.tool] else {
            fail("\(step.tool) is not installed, so “\(step.label)” cannot run.")
            return
        }

        let (executable, arguments) = step.requiresRoot
            ? privileges.wrapped(tool, step.arguments)
            : (tool, step.arguments)

        phase = .working(step.label)
        append("→ \(step.label): \(pretty(executable, arguments))")
        if let note = step.note {
            append("  \(note)")
        }

        let process = ShellProcess(
            executable: executable,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment
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
                } else {
                    self.fail(self.failureMessage(for: step, outcome: outcome))
                }
            })
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func finish() {
        store?.refreshToolchain()
        phase = .finished("Theos installed in \(destination).")
        append("Done. Theos is now used from \(destination).")
    }

    // MARK: - Reporting

    private func failureMessage(for step: InstallStep, outcome: ShellProcess.Outcome) -> String {
        let tail = outcome.output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? "no output"
        var message = "\(step.label) failed (exit \(outcome.status)): \(tail)"
        if step.requiresRoot && !privileges.canEscalate {
            message += "\n\n" + privileges.remedy(for: pretty(toolPaths[step.tool] ?? step.tool, step.arguments))
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
