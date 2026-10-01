import Foundation

/// What the agent is allowed to do without asking.
///
/// The default is the one that cannot surprise anyone: reading is free, and
/// anything that changes the project or the device stops for a tap. The looser
/// settings exist for people who have watched it work and would rather not
/// approve forty small edits in a row — and every one of them still refuses a
/// path that leaves the project, because that is a rule and not a preference.
public enum AgentApprovalPolicy: String, CaseIterable, Sendable, Identifiable {
    case askForChanges
    case askForBuildsAndInstalls
    case askForInstallsOnly
    case fullAuto

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .askForChanges: return "Ask for every change"
        case .askForBuildsAndInstalls: return "Ask to build or install"
        case .askForInstallsOnly: return "Ask to install only"
        case .fullAuto: return "Do not ask"
        }
    }

    public var summary: String {
        switch self {
        case .askForChanges:
            return "Reads are free; every edit, build and install shows a diff or a command and waits for you."
        case .askForBuildsAndInstalls:
            return "Edits are applied as they come, with the diff in the transcript. Building and installing still ask."
        case .askForInstallsOnly:
            return "Everything is applied as it comes, and only installing the package on the device stops for a tap."
        case .fullAuto:
            return "Nothing stops for approval. The transcript still shows every change — but you see it after the fact, so use this on a project you can rebuild."
        }
    }

    /// Whether this access level needs a tap.
    public func needsApproval(for access: AgentAccess) -> Bool {
        switch self {
        case .fullAuto:
            return false
        case .askForChanges:
            return access != .read
        case .askForBuildsAndInstalls:
            return access == .build || access == .install
        case .askForInstallsOnly:
            return access == .install
        }
    }
}

/// A standing instruction, as a switch rather than a paragraph.
///
/// Each of these is one line in the system prompt. They are switches because the
/// wording matters and hand-written instructions drift; a user who wants
/// something else writes it in their own words in the extra instructions.
public enum AgentPreference: String, CaseIterable, Sendable, Identifiable {
    case explainFirst
    case minimalDiffs
    case confirmPrivateAPIs
    case addLogging
    case commentTheWhy
    case sayHowToVerify
    case keepFilterNarrow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .explainFirst: return "Explain before changing"
        case .minimalDiffs: return "Prefer the smallest change"
        case .confirmPrivateAPIs: return "Never assume a private API"
        case .addLogging: return "Add logging to every hook"
        case .commentTheWhy: return "Comment the why, not the what"
        case .sayHowToVerify: return "Say how to verify the change"
        case .keepFilterNarrow: return "Keep the injection filter narrow"
        }
    }

    public var summary: String {
        switch self {
        case .explainFirst:
            return "One sentence about what it is about to do, before the tool call."
        case .minimalDiffs:
            return "replace_in_file over rewrites, and existing formatting and comments left alone."
        case .confirmPrivateAPIs:
            return "Search the headers before hooking a name, and say when a name is unconfirmed."
        case .addLogging:
            return "An NSLog with the tweak's name in every hook, so its effect is visible in the log."
        case .commentTheWhy:
            return "Comments that explain intent; the code already says what it does."
        case .sayHowToVerify:
            return "Ends a turn with what to do on the device to see the change take effect."
        case .keepFilterNarrow:
            return "The injection filter targets one process, never everything."
        }
    }

    /// The line that goes into the system prompt.
    public var promptLine: String {
        switch self {
        case .explainFirst:
            return "Say in one sentence what you are about to do and why, before calling a tool that changes a file."
        case .minimalDiffs:
            return "Prefer the smallest possible change: use replace_in_file rather than rewriting a file, and leave existing formatting and comments as they are."
        case .confirmPrivateAPIs:
            return "Treat every private class and method name as unconfirmed until search_headers or the user confirms it, and say so when you cannot."
        case .addLogging:
            return "Put an NSLog carrying the tweak's name in every hook you write, so the user can see in the log that it fired."
        case .commentTheWhy:
            return "Write comments that explain why the code is the way it is, not what the line above it does."
        case .sayHowToVerify:
            return "Finish with what the user should do on the device to see the change take effect."
        case .keepFilterNarrow:
            return "Keep the injection filter targeting a single process; never widen it to every process."
        }
    }

    public static func promptLines(for preferences: Set<AgentPreference>) -> [String] {
        AgentPreference.allCases
            .filter { preferences.contains($0) }
            .map(\.promptLine)
    }
}

/// How much of the project goes into every request.
public enum AgentContextMode: String, CaseIterable, Sendable, Identifiable {
    /// The file contents are sent, so the agent rarely needs to read anything.
    case fullFiles
    /// Only the file names are sent; the agent reads what it needs. Smaller
    /// requests, and less of the project leaves the device.
    case namesOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fullFiles: return "Send the project's files"
        case .namesOnly: return "Send only the file names"
        }
    }

    public var summary: String {
        switch self {
        case .fullFiles:
            return "The Makefile, control, Logos sources and plists ride along with every request, cut to the budget below. Fewer read_file round trips."
        case .namesOnly:
            return "The agent gets the file list and reads what it needs with read_file. Smaller requests, and less of the project leaves the device."
        }
    }
}
