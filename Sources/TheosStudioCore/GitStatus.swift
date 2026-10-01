import Foundation

/// One changed file, as `git status --porcelain` describes it.
public struct GitFile: Equatable, Sendable, Identifiable {
    public var path: String
    /// The staged status letter (`M`, `A`, `D`, `R`, `?` …).
    public var indexStatus: Character
    /// The working-tree status letter.
    public var worktreeStatus: Character
    /// Set for a rename: the path that was there before.
    public var originalPath: String?

    public var id: String { path }

    public var isUntracked: Bool { indexStatus == "?" }
    public var isStaged: Bool { indexStatus != " " && indexStatus != "?" }
    public var isModified: Bool { worktreeStatus != " " }

    /// What happened to the file, in words, because a letter pair is not a
    /// sentence and this is shown on a phone.
    public var label: String {
        if isUntracked { return "Untracked" }
        var parts: [String] = []
        let staged = Self.word(for: indexStatus)
        let unstaged = Self.word(for: worktreeStatus)
        if let staged { parts.append("staged: \(staged)") }
        if let unstaged, unstaged != staged { parts.append("working tree: \(unstaged)") }
        if parts.isEmpty { parts.append("changed") }
        return parts.joined(separator: ", ")
    }

    static func word(for status: Character) -> String? {
        switch status {
        case "M": return "modified"
        case "A": return "added"
        case "D": return "deleted"
        case "R": return "renamed"
        case "C": return "copied"
        case "U": return "conflicted"
        case "?": return "untracked"
        case "!": return "ignored"
        default: return nil
        }
    }
}

/// Turns git's output into something the app can show, and the commands it runs
/// into something the engine can test.
public enum GitPorcelain {

    /// Parses `git status --porcelain` (`-z` output is not used: project paths
    /// here are small and readable, and a NUL-separated stream does not survive
    /// being shown to a person).
    public static func parse(_ output: String) -> [GitFile] {
        var files: [GitFile] = []
        for rawLine in output.normalisedLineEndings().split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.count >= 4 else { continue }
            let characters = Array(line)
            let indexStatus = characters[0]
            let worktreeStatus = characters[1]
            var path = String(characters[3...])

            var originalPath: String?
            if let arrow = path.range(of: " -> ") {
                originalPath = String(path[path.startIndex..<arrow.lowerBound])
                path = String(path[arrow.upperBound...])
            }
            // `git status` quotes paths with unusual characters.
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            files.append(GitFile(
                path: path,
                indexStatus: indexStatus,
                worktreeStatus: worktreeStatus,
                originalPath: originalPath
            ))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public static func summary(_ files: [GitFile]) -> String {
        guard !files.isEmpty else { return "No changes." }
        let staged = files.filter(\.isStaged).count
        let untracked = files.filter(\.isUntracked).count
        var parts: [String] = ["\(files.count) changed file\(files.count == 1 ? "" : "s")"]
        if staged > 0 { parts.append("\(staged) staged") }
        if untracked > 0 { parts.append("\(untracked) untracked") }
        return parts.joined(separator: ", ") + "."
    }
}

/// The git invocations the app can make, as argument vectors.
///
/// `-C <project>` rather than a working directory, for the same reason the build
/// uses `make -C`: chdir-on-spawn does not exist on iOS.
public enum GitCommands {

    public static func status(project: String) -> [String] {
        ["-C", project, "status", "--porcelain"]
    }

    public static func branch(project: String) -> [String] {
        ["-C", project, "rev-parse", "--abbrev-ref", "HEAD"]
    }

    public static func log(project: String, limit: Int = 10) -> [String] {
        ["-C", project, "log", "--oneline", "-n", String(limit)]
    }

    public static func diff(project: String, path: String? = nil, staged: Bool = false) -> [String] {
        var arguments = ["-C", project, "diff"]
        if staged { arguments.append("--cached") }
        arguments.append("--no-color")
        if let path, !path.isEmpty { arguments.append(contentsOf: ["--", path]) }
        return arguments
    }

    public static func diffStat(project: String) -> [String] {
        ["-C", project, "diff", "--stat", "--no-color"]
    }

    public static func initRepository(project: String) -> [String] {
        ["-C", project, "init"]
    }

    /// Stages everything, which is what "commit my work" means in a project this
    /// size — the alternative is a staging UI for five files.
    public static func addAll(project: String) -> [String] {
        ["-C", project, "add", "-A"]
    }

    public static func commit(project: String, message: String) -> [String] {
        ["-C", project, "commit", "-m", message]
    }

    public static func firstCommitIdentityCheck(project: String) -> [String] {
        ["-C", project, "config", "--get", "user.email"]
    }

    public static func setIdentity(project: String, name: String, email: String) -> [[String]] {
        [
            ["-C", project, "config", "user.name", name],
            ["-C", project, "config", "user.email", email],
        ]
    }

    /// A `.git` directory is what makes a folder a repository; the app checks for
    /// this before offering any of the above.
    public static func isRepository(project: String, exists: (String) -> Bool) -> Bool {
        exists(project + "/.git")
    }
}
