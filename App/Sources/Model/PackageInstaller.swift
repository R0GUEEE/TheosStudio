import Foundation
import TheosStudioCore

/// Installs the packages a build produces, and removes them again.
///
/// Everything here is `dpkg` on the device — the same tool Sileo ends up calling.
/// There is no second package database and no rewriting of the install tree, so a
/// package installed from the app is indistinguishable from one installed any
/// other way.
@MainActor
final class PackageInstaller: ObservableObject {

    struct InstalledPackage: Identifiable, Equatable {
        let identifier: String
        let name: String
        let version: String
        var id: String { identifier }
    }

    enum Phase: Equatable {
        case idle
        case working(String)
        case finished(String)
        case failed(String)

        var isRunning: Bool {
            if case .working = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log: [String] = []
    @Published private(set) var installed: [InstalledPackage] = []
    @Published private(set) var isRoot: Bool = PackageInstaller.isRunningAsRoot

    /// dpkg needs root for the parts of the filesystem it writes. The app says so
    /// rather than pretending the failure was the package's fault.
    static var isRunningAsRoot: Bool { geteuid() == 0 }

    private var process: ShellProcess?
    /// Called once when an install/remove/respring finishes, for callers that
    /// need the result as a value rather than as a published phase.
    var onResult: ((Bool, String) -> Void)?

    // MARK: - Installing

    /// `dpkg -i` the package, then respring if the settings say so.
    func install(debPath: String, store: StudioStore) {
        guard !phase.isRunning else { return }
        guard FS.fileExists(debPath) else {
            let message = "The package is gone: \(debPath)"
            phase = .failed(message)
            onResult?(false, message)
            return
        }
        log = ["Installing \(debPath)"]

        guard let dpkg = toolPath(named: "dpkg", store: store) else {
            let message = "dpkg was not found, so nothing can be installed. Install the 'dpkg' package first."
            phase = .failed(message)
            onResult?(false, message)
            return
        }

        log.append("Privileges: \(store.privileges.summary)")
        phase = .working("Installing")
        let command = store.privileges.wrapped(dpkg, ["-i", debPath])
        run(command.executable, command.arguments) { [weak self] outcome in
            guard let self else { return }
            if outcome.succeeded {
                self.log.append("Installed.")
                self.onResult?(true, "Installed \(debPath)")
                if store.settings.respringAfterInstall {
                    self.respring(store: store)
                } else {
                    self.phase = .finished("Installed. Respring to load it.")
                }
            } else {
                // dpkg's own message is the useful part; the app adds the one
                // thing dpkg cannot know, which is that this app may not be
                // allowed to write where dpkg needs to.
                var reason = self.lastMeaningfulLine(outcome.output) ?? "dpkg exited with status \(outcome.status)"
                if !store.privileges.canEscalate {
                    // Say what to do about it, not just what went wrong.
                    reason += "\n\n" + store.privileges.remedy(for: "\(dpkg) -i '\(debPath)'")
                }
                self.log.append(reason)
                self.phase = .failed(reason)
                self.onResult?(false, reason)
            }
        }
    }

    func remove(identifier: String, store: StudioStore) {
        guard !phase.isRunning else { return }
        guard let dpkg = toolPath(named: "dpkg", store: store) else {
            phase = .failed("dpkg was not found.")
            return
        }
        log = ["Removing \(identifier)"]
        phase = .working("Removing")
        let command = store.privileges.wrapped(dpkg, ["-r", identifier])
        run(command.executable, command.arguments) { [weak self] outcome in
            guard let self else { return }
            if outcome.succeeded {
                self.log.append("Removed \(identifier).")
                self.phase = .finished("Removed \(identifier).")
                self.refreshInstalled(store: store)
            } else {
                let reason = self.lastMeaningfulLine(outcome.output) ?? "dpkg exited with status \(outcome.status)"
                self.log.append(reason)
                self.phase = .failed(reason)
            }
        }
    }

    /// `sbreload` is the jailbreak-native way to restart SpringBoard without
    /// dropping into safe mode; `killall` is the fallback every setup has.
    func respring(store: StudioStore) {
        phase = .working("Respringing")
        if let reload = toolPath(named: "sbreload", store: store) {
            let command = store.privileges.wrapped(reload, [])
            run(command.executable, command.arguments) { [weak self] outcome in
                self?.finishRespring(outcome, command: "sbreload")
            }
            return
        }
        if let killall = toolPath(named: "killall", store: store) {
            let command = store.privileges.wrapped(killall, ["-9", "SpringBoard"])
            run(command.executable, command.arguments) { [weak self] outcome in
                self?.finishRespring(outcome, command: "killall -9 SpringBoard")
            }
            return
        }
        phase = .failed("Neither sbreload nor killall is installed, so the app cannot restart SpringBoard itself.")
    }

    private func finishRespring(_ outcome: ShellProcess.Outcome, command: String) {
        if outcome.succeeded || outcome.status == 128 + 9 {
            // killall returns non-zero when the process was killed by the signal
            // it sent, depending on the implementation.
            log.append("Resprung (\(command)).")
            phase = .finished("Installed.")
        } else {
            let reason = lastMeaningfulLine(outcome.output) ?? "\(command) exited with status \(outcome.status)"
            log.append(reason)
            phase = .failed(reason)
        }
    }

    // MARK: - Listing

    func refreshInstalled(store: StudioStore) {
        guard let query = toolPath(named: "dpkg-query", store: store) else { return }
        run(query, ["-W", "-f", "${Package}\t${Version}\n"]) { [weak self] outcome in
            guard let self else { return }
            self.installed = Self.parseInstalled(outcome.output)
        }
    }

    static func parseInstalled(_ output: String) -> [InstalledPackage] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> InstalledPackage? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard let identifier = parts.first, !identifier.isEmpty else { return nil }
                let version = parts.count > 1 ? parts[1] : ""
                return InstalledPackage(identifier: identifier, name: identifier, version: version)
            }
            .sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
    }

    // MARK: - Plumbing

    private func run(_ executable: String, _ arguments: [String], completion: @escaping (ShellProcess.Outcome) -> Void) {
        let process = ShellProcess(executable: executable, arguments: arguments, environment: ProcessInfo.processInfo.environment)
        self.process = process
        do {
            try process.run(onLine: { [weak self] line in
                self?.log.append(line)
            }, onExit: { [weak self] outcome in
                self?.process = nil
                completion(outcome)
            })
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Looks for a tool the engine's list does not cover (`dpkg-query`) in the
    /// same directories the build uses.
    private func toolPath(named name: String, store: StudioStore) -> String? {
        if let path = store.toolchain?.status(for: name)?.path { return path }
        let directories = store.toolchain?.binDirectories ?? store.jailbreak.binDirectories
        return ToolLocator.locate(name, in: directories, exists: FS.fileExists)
    }

    private func lastMeaningfulLine(_ output: String) -> String? {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

/// Small file-backed `which`, used for the tools the engine does not model.
enum ToolLocator {
    static func locate(_ name: String, in directories: [String], exists: (String) -> Bool) -> String? {
        directories.first { exists($0 + "/" + name) }.map { $0 + "/" + name }
    }
}
