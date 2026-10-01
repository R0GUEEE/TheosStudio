import Foundation
import TheosStudioCore

/// The result of one command, with the output the UI needs to show.
struct CommandResult {
    var status: Int32
    var output: String
    var succeeded: Bool { status == 0 }
}

/// Running git inside a project.
///
/// Every command goes through `commandEnvironment()`, which is the difference
/// between `git clone`/`git diff` working and failing on a device whose PATH does
/// not include the jailbreak's binaries.
@MainActor
enum GitService {

    static func toolPath(store: StudioStore) -> String? {
        store.toolPaths(for: ["git"])["git"]
    }

    static func isRepository(project: String) -> Bool {
        GitCommands.isRepository(project: project, exists: FS.directoryExists)
    }

    static func run(project: String, arguments: [String], store: StudioStore) async -> CommandResult {
        guard let git = toolPath(store: store) else {
            return CommandResult(status: 127, output: "git is not installed. Install it from Sileo.")
        }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let process = ShellProcess(
                executable: git,
                arguments: arguments,
                environment: store.commandEnvironment()
            )
            var collected = ""
            do {
                try process.run(onLine: { line in
                    collected += line + "\n"
                }, onExit: { outcome in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: CommandResult(
                        status: outcome.status,
                        output: collected.isEmpty ? outcome.output : collected
                    ))
                })
            } catch {
                continuation.resume(returning: CommandResult(status: 127, output: error.localizedDescription))
            }
        }
    }

    static func status(project: String, store: StudioStore) async -> [GitFile] {
        let result = await run(project: project, arguments: GitCommands.status(project: project), store: store)
        return GitPorcelain.parse(result.output)
    }

    static func branch(project: String, store: StudioStore) async -> String? {
        let result = await run(project: project, arguments: GitCommands.branch(project: project), store: store)
        guard result.succeeded else { return nil }
        let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func diff(project: String, path: String?, staged: Bool = false, store: StudioStore) async -> String {
        let result = await run(
            project: project,
            arguments: GitCommands.diff(project: project, path: path, staged: staged),
            store: store
        )
        return result.output
    }

    static func diffStat(project: String, store: StudioStore) async -> String {
        let result = await run(project: project, arguments: GitCommands.diffStat(project: project), store: store)
        return result.output
    }

    /// Stages everything and commits. A project here is five files, so a staging
    /// UI would be more taps for less information.
    static func commitAll(project: String, message: String, store: StudioStore) async -> CommandResult {
        let identity = await ensureIdentity(project: project, store: store)
        if let identity, !identity.succeeded {
            return identity
        }
        let add = await run(project: project, arguments: GitCommands.addAll(project: project), store: store)
        guard add.succeeded else { return add }
        return await run(project: project, arguments: GitCommands.commit(project: project, message: message), store: store)
    }

    static func initialise(project: String, store: StudioStore) async -> CommandResult {
        let result = await run(project: project, arguments: GitCommands.initRepository(project: project), store: store)
        guard result.succeeded else { return result }
        _ = await ensureIdentity(project: project, store: store)
        // An iOS project should not commit its build products.
        let ignore = """
        .theos/
        packages/
        obj/
        *.o
        .DS_Store
        """
        try? FS.write(ignore, to: project + "/.gitignore")
        return result
    }

    /// A repository with no identity refuses to commit, and the error message
    /// ("please tell me who you are") is not something to hand a user who just
    /// tapped Commit.
    private static func ensureIdentity(project: String, store: StudioStore) async -> CommandResult? {
        let existing = await run(project: project, arguments: GitCommands.firstCommitIdentityCheck(project: project), store: store)
        guard !existing.succeeded else { return nil }
        for arguments in GitCommands.setIdentity(
            project: project,
            name: store.settings.authorName,
            email: store.settings.authorEmail
        ) {
            _ = await run(project: project, arguments: arguments, store: store)
        }
        return nil
    }
}

/// Finding and reading the device's crash logs.
@MainActor
enum CrashService {

    /// Names worth looking for in a report: the project's name and its package id,
    /// because a tweak's dylib is named after the project, not after the package.
    static func interestingNames(for project: Project) -> [String] {
        var names = [project.name]
        if let identifier = project.packageIdentifier {
            names.append(identifier)
            names.append((identifier as NSString).lastPathComponent)
        }
        return names
    }

    static func summaries(store: StudioStore, names: [String], limit: Int = 20) -> [CrashLogSummary] {
        var summaries: [CrashLogSummary] = []
        var seen = Set<String>()

        for directory in CrashLogParser.candidateDirectories(jailbreak: store.jailbreak, home: NSHomeDirectory()) {
            guard FS.directoryExists(directory) else { continue }
            // Newest first by filename: iOS names them with a timestamp, which
            // sorts correctly as a string.
            let files = FS.list(directory)
                .filter { $0.hasSuffix(".ips") || $0.hasSuffix(".crash") }
                .sorted(by: >)
                .prefix(limit)

            for file in files {
                let path = directory + "/" + file
                guard seen.insert(path).inserted else { continue }
                guard FS.size(path) < 4 * 1024 * 1024 else { continue }
                guard let contents = FS.read(path) else { continue }
                summaries.append(CrashLogParser.parse(fileName: file, contents: contents, interestingNames: names))
            }
        }

        // Our crashes first, then newest, because the one you are looking for is
        // almost always the one your tweak caused.
        return summaries
            .sorted { lhs, rhs in
                if lhs.mentionsOurs != rhs.mentionsOurs { return lhs.mentionsOurs }
                return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }
}

/// Creating, renaming and deleting files in a project — including the half that
/// is easy to forget.
@MainActor
enum ProjectFileEditor {

    struct Outcome: Identifiable {
        let id = UUID()
        var notes: [String] = []
        var warnings: [String] = []
    }

    /// A Logos skeleton, so a new file is not an empty screen.
    static func defaultContents(for path: String, projectName: String) -> String {
        let lower = path.lowercased()
        if lower.hasSuffix(".x") || lower.hasSuffix(".xm") {
            let base = (path as NSString).lastPathComponent
            let className = base.replacingOccurrences(of: ".xm", with: "").replacingOccurrences(of: ".x", with: "")
            return """
            // \(base) — \(projectName)
            //
            // Declare only what you use. A hook for a class or selector that does
            // not exist on this iOS version does not fail: it silently never
            // fires, so confirm the names against the device before relying on them.

            #import <UIKit/UIKit.h>

            %hook \(className)

            - (void)example {
                %orig;
                NSLog(@"[\(projectName)] \(className) example");
            }

            %end
            """
        }
        if lower.hasSuffix(".m") || lower.hasSuffix(".mm") {
            let base = (path as NSString).lastPathComponent
            let className = base.replacingOccurrences(of: ".mm", with: "").replacingOccurrences(of: ".m", with: "")
            return """
            #import "\(className).h"

            @implementation \(className)

            @end
            """
        }
        if lower.hasSuffix(".h") {
            let className = (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".h", with: "")
            return """
            #import <Foundation/Foundation.h>

            @interface \(className) : NSObject
            @end
            """
        }
        return ""
    }

    static func create(
        project: String,
        path: String,
        contents: String,
        addToMakefile: Bool
    ) throws -> Outcome {
        var outcome = Outcome()
        let fullPath = project + "/" + path
        try FS.write(contents, to: fullPath)

        guard addToMakefile, MakefileEditor.isSourceFile(path) else {
            if MakefileEditor.isSourceFile(path) && !addToMakefile {
                outcome.notes.append("Not added to the Makefile's file list, so it will not be compiled until you add it there.")
            }
            return outcome
        }

        let makefilePath = project + "/Makefile"
        guard let makefile = FS.read(makefilePath) else {
            outcome.warnings.append("There is no Makefile to add \(path) to.")
            return outcome
        }
        let result = MakefileEditor.addSource(path, to: makefile)
        if result.changed {
            try FS.write(result.text, to: makefilePath)
            outcome.notes.append("Added \(path) to the Makefile's file list.")
        } else if let reason = result.reason {
            outcome.warnings.append(reason)
        }
        return outcome
    }

    static func rename(project: String, from: String, to: String) throws -> Outcome {
        var outcome = Outcome()
        let source = project + "/" + from
        let destination = project + "/" + to

        try FS.createDirectory((destination as NSString).deletingLastPathComponent)
        if FS.fileExists(destination) {
            throw StudioError.directoryExists(destination)
        }
        try FileManager.default.moveItem(atPath: source, toPath: destination)

        // The file list follows the file, or the build silently loses a source.
        guard MakefileEditor.isSourceFile(from) || MakefileEditor.isSourceFile(to),
              let makefile = FS.read(project + "/Makefile") else { return outcome }

        let removed = MakefileEditor.removeSource(from, from: makefile)
        var text = removed.text
        if MakefileEditor.isSourceFile(to) {
            let added = MakefileEditor.addSource(to, to: text)
            text = added.text
            if added.changed {
                outcome.notes.append("Updated the Makefile for \(to).")
            }
        }
        if text != makefile {
            try FS.write(text, to: project + "/Makefile")
        }
        return outcome
    }

    static func delete(project: String, path: String) throws -> Outcome {
        var outcome = Outcome()
        try FS.remove(project + "/" + path)

        guard MakefileEditor.isSourceFile(path),
              let makefile = FS.read(project + "/Makefile") else { return outcome }
        let result = MakefileEditor.removeSource(path, from: makefile)
        if result.changed {
            try FS.write(result.text, to: project + "/Makefile")
            outcome.notes.append("Removed \(path) from the Makefile's file list.")
        }
        return outcome
    }
}
