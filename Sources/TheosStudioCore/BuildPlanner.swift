import Foundation

/// POSIX shell quoting, used for the one-string form of a command.
///
/// The app spawns processes with an argument vector, never through a shell, so
/// this is only ever used to *display* the command. It still has to be correct:
/// the displayed line is what the user copies into a terminal.
public enum ShellQuote {
    public static func quote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+=:,./-")
        if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return argument
        }
        // Close the quote, emit an escaped quote, reopen: 'it'\''s'.
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }
}

public struct BuildRequest: Equatable, Sendable {
    /// Absolute path of the project directory (the one holding the Makefile).
    public var projectPath: String
    public var scheme: PackagingScheme
    /// `FINALPACKAGE=1`: optimised and stripped, the build you actually ship.
    public var finalPackage: Bool
    /// Run `make clean` first. Theos does not track header dependencies, so a
    /// stale object file is the usual cause of "my change did nothing".
    public var cleanFirst: Bool
    /// `messages=yes`, which makes Theos stop hiding the compile lines.
    public var verbose: Bool
    /// Parallel make. `nil` leaves Theos's default alone.
    public var jobs: Int?
    /// Extra `NAME=value` assignments appended to the make command line.
    public var extraVariables: [String: String]
    /// Extra arguments inserted before the target, e.g. `-k`.
    public var extraArguments: [String]

    public init(
        projectPath: String,
        scheme: PackagingScheme,
        finalPackage: Bool = false,
        cleanFirst: Bool = false,
        verbose: Bool = true,
        jobs: Int? = nil,
        extraVariables: [String: String] = [:],
        extraArguments: [String] = []
    ) {
        self.projectPath = projectPath
        self.scheme = scheme
        self.finalPackage = finalPackage
        self.cleanFirst = cleanFirst
        self.verbose = verbose
        self.jobs = jobs
        self.extraVariables = extraVariables
        self.extraArguments = extraArguments
    }
}

public struct BuildCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    /// The command as a single line, for the console.
    public var display: String

    public init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.display = ShellQuote.join([executable] + arguments)
    }
}

public enum BuildPlanner {
    /// The directory Theos writes finished packages into.
    public static func packagesDirectory(for projectPath: String) -> String {
        projectPath + "/packages"
    }

    /// The directory Theos writes intermediate objects into.
    public static func buildDirectory(for projectPath: String) -> String {
        projectPath + "/.theos"
    }

    /// Builds the command sequence for a request.
    ///
    /// `-C` is used instead of a working directory because `chdir`-on-spawn is
    /// not available on iOS (`posix_spawn_file_actions_addchdir_np` is
    /// `API_UNAVAILABLE(ios)`), and running through a shell would need `/bin/sh`
    /// to exist at a path that is not the same on rootful and rootless setups.
    public static func plan(
        for request: BuildRequest,
        make executable: String,
        environment: [String: String]
    ) -> [BuildCommand] {
        var commands: [BuildCommand] = []
        if request.cleanFirst {
            commands.append(BuildCommand(
                executable: executable,
                arguments: baseArguments(for: request) + ["clean"],
                environment: environment
            ))
        }
        commands.append(BuildCommand(
            executable: executable,
            arguments: baseArguments(for: request) + variables(for: request) + ["package"],
            environment: environment
        ))
        return commands
    }

    static func baseArguments(for request: BuildRequest) -> [String] {
        var arguments = ["-C", request.projectPath]
        if let jobs = request.jobs, jobs > 1 {
            arguments.append("-j\(jobs)")
        }
        arguments.append(contentsOf: request.extraArguments)
        return arguments
    }

    /// The `NAME=value` assignments, in a stable order so the console line is the
    /// same on every build.
    static func variables(for request: BuildRequest) -> [String] {
        var variables: [String: String] = [:]
        if let value = request.scheme.theosVariableValue {
            variables["THEOS_PACKAGE_SCHEME"] = value
        }
        if request.finalPackage {
            variables["FINALPACKAGE"] = "1"
        }
        if request.verbose {
            variables["messages"] = "yes"
        }
        for (key, value) in request.extraVariables {
            variables[key] = value
        }
        return variables.keys.sorted().map { "\($0)=\(variables[$0] ?? "")" }
    }
}

/// Finds the artefact a build produced.
public enum ArtifactLocator {

    /// The newest `.deb` in `<project>/packages`, by modification time.
    ///
    /// Sorting by date rather than by name matters: Theos names the file after
    /// the package and version, so an unchanged version produces an unchanged
    /// name, and the file the build just wrote is the one to install.
    public static func newestPackage(
        in projectPath: String,
        listDirectory: (String) -> [String],
        modificationDate: (String) -> Date?
    ) -> String? {
        let directory = BuildPlanner.packagesDirectory(for: projectPath)
        let candidates = listDirectory(directory)
            .filter { $0.hasSuffix(".deb") }
            .map { directory + "/" + $0 }
        return candidates.max { lhs, rhs in
            let left = modificationDate(lhs) ?? .distantPast
            let right = modificationDate(rhs) ?? .distantPast
            if left == right {
                // Stable tie-break so the choice is deterministic.
                return lhs < rhs
            }
            return left < right
        }
    }
}
