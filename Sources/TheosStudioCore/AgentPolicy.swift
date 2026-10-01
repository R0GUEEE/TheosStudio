import Foundation

/// What the app will do with an action, decided before the model's turn
/// continues. This is the whole safety story of the assistant: it can read
/// freely, and anything that changes the project is shown to the user first.
public enum AgentDecision: Equatable, Sendable {
    case allowed
    case needsApproval(reason: String)
    /// Refused, with the reason handed back to the model as the tool result.
    case refused(reason: String)
}

/// What an action does to the world, in the terms an approval policy is written
/// in. Kept separate from the policy so "what is this" and "may it run" can be
/// reasoned about (and tested) apart.
public enum AgentAccess: Equatable, Sendable {
    case read
    case write
    case build
    case install
}

public enum AgentPolicy {

    /// Classifies an action. A refused action never reaches here, so anything
    /// unknown is treated as a write — the cautious answer.
    public static func access(for action: AgentAction) -> AgentAccess {
        switch action {
        case .listFiles, .readFile, .readCrashes, .gitStatus, .gitDiff, .searchHeaders,
             .workspaceStatus, .projectHealth, .projectStats, .listLaunchTargets,
             .inspectPackage, .installedPackages, .listPlugins, .finish:
            return .read
        case .writeFile, .replaceInFile, .updateControl, .runPlugin:
            return .write
        case .build:
            return .build
        case .install, .restartTarget:
            return .install
        case .unknown:
            return .write
        }
    }


    /// The largest file worth putting in front of a model or writing by hand.
    public static let maxFileBytes = 256 * 1024

    /// Normalises a path against the project root, or returns nil when it points
    /// outside it.
    ///
    /// The assistant is given a project, not a device. Every path it produces is
    /// relative and is checked here, because a model that has seen `/var/jb/...`
    /// in an error message will happily try to write there.
    public static func relativePath(_ path: String) -> String? {
        var candidate = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        guard !candidate.hasPrefix("/"), !candidate.hasPrefix("~") else { return nil }
        guard !candidate.contains("\0") else { return nil }
        if candidate.hasPrefix("./") {
            candidate = String(candidate.dropFirst(2))
        }
        let components = candidate.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return nil }
        guard !components.contains("..") else { return nil }
        return components.joined(separator: "/")
    }

    /// Build output, not source. Writing into it would produce a change that the
    /// next build silently overwrites.
    public static func isBuildOutput(_ relativePath: String) -> Bool {
        relativePath.hasPrefix("packages/") || relativePath.hasPrefix(".theos/") || relativePath.hasPrefix("obj/")
    }

    /// The full decision: sandbox rules first (which no setting can loosen), then
    /// whether the tool is enabled, then whether this policy wants a tap.
    public static func decide(
        _ action: AgentAction,
        approvals: AgentApprovalPolicy = .askForChanges,
        enabledTools: Set<String>? = nil,
        privilegesCanEscalate: Bool
    ) -> AgentDecision {
        if let enabledTools, !enabledTools.contains(action.toolName) {
            return .refused(reason: "The \(action.toolName) tool is turned off in the assistant's settings. Ask the user to enable it, or do this another way.")
        }

        switch decideSandbox(action, privilegesCanEscalate: privilegesCanEscalate) {
        case .refused(let reason):
            return .refused(reason: reason)
        case .allowed, .needsApproval:
            let access = access(for: action)
            guard approvals.needsApproval(for: access) else {
                // Auto-approved: say so in the transcript's wording, but the
                // decision is the same one the approval sheet would have made.
                return .allowed
            }
            // The reason is what the approval sheet shows, so it comes from the
            // sandbox pass rather than being invented here.
            if case .needsApproval(let reason) = decideSandbox(action, privilegesCanEscalate: privilegesCanEscalate) {
                return .needsApproval(reason: reason)
            }
            return .needsApproval(reason: action.summary)
        }
    }

    /// The rules that hold whatever the settings say.
    static func decideSandbox(_ action: AgentAction, privilegesCanEscalate: Bool) -> AgentDecision {
        switch action {
        case .listFiles, .finish, .readCrashes, .gitStatus, .searchHeaders,
             .workspaceStatus, .projectHealth, .projectStats, .listLaunchTargets,
             .inspectPackage, .installedPackages, .listPlugins:
            return .allowed

        case .gitDiff(let path):
            guard let path, !path.isEmpty else { return .allowed }
            guard let relative = relativePath(path) else {
                return .refused(reason: "git_diff only accepts a path inside the project. '\(path)' is not one.")
            }
            _ = relative
            return .allowed

        case .readFile(let path):
            guard let relative = relativePath(path) else {
                return .refused(reason: "read_file only accepts a path inside the project, relative to its root. '\(path)' is not one.")
            }
            guard !isBuildOutput(relative) else {
                return .refused(reason: "'\(relative)' is build output, not source. The files worth reading are the Makefile, control, the Logos source and the filter plist.")
            }
            return .allowed

        case .writeFile(let path, let contents):
            guard let relative = relativePath(path) else {
                return .refused(reason: "write_file only accepts a path inside the project, relative to its root. '\(path)' is not one.")
            }
            guard !isBuildOutput(relative) else {
                return .refused(reason: "'\(relative)' is build output; it is regenerated by every build.")
            }
            guard contents.utf8.count <= maxFileBytes else {
                return .refused(reason: "That file would be \(contents.utf8.count) bytes, which is larger than anything a tweak needs. Write it in smaller pieces.")
            }
            return .needsApproval(reason: "Write \(relative)")

        case .replaceInFile(let path, _, _):
            guard let relative = relativePath(path) else {
                return .refused(reason: "replace_in_file only accepts a path inside the project, relative to its root. '\(path)' is not one.")
            }
            guard !isBuildOutput(relative) else {
                return .refused(reason: "'\(relative)' is build output; it is regenerated by every build.")
            }
            return .needsApproval(reason: "Edit \(relative)")

        case .updateControl(let key, let value):
            return .needsApproval(reason: value == nil ? "Remove \(key) from control" : "Set \(key) in control")

        case .build:
            return .needsApproval(reason: "Run make in the project")

        case .install:
            let note = privilegesCanEscalate
                ? "Install the built package and respring"
                : "Install the built package — this app cannot become root, so this will fail unless the package is installed from a package manager"
            return .needsApproval(reason: note)

        case .runPlugin(let pluginID, let actionID):
            return .needsApproval(reason: "Run plugin action \(pluginID) / \(actionID)")

        case .restartTarget(let name):
            return .needsApproval(reason: "Restart \(name)")

        case .unknown(_, let reason):
            return .refused(reason: reason)
        }
    }
}
