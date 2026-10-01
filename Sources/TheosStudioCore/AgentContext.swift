import Foundation

public struct ProjectFile: Equatable, Sendable {
    public var path: String
    public var contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

/// Everything about a project the assistant is told before it starts.
public struct AgentProjectSnapshot: Equatable, Sendable {
    public var name: String
    public var path: String
    public var kind: ProjectKind?
    public var scheme: PackagingScheme
    public var packageIdentifier: String?
    public var version: String?
    public var files: [ProjectFile]
    /// The last build's errors and warnings, already formatted.
    public var buildSummary: String?
    /// What this device can do: Theos location, SDKs, privileges.
    public var toolchainSummary: String?
    /// App-wide workspace state: projects, plugins, installed packages and other
    /// context that is useful beyond one source tree.
    public var appSummary: String?
    /// The project's own AGENT.md, when it has one: standing instructions the user
    /// wrote for this project, in the project.
    public var briefing: String?

    public init(
        name: String,
        path: String,
        kind: ProjectKind?,
        scheme: PackagingScheme,
        packageIdentifier: String? = nil,
        version: String? = nil,
        files: [ProjectFile] = [],
        buildSummary: String? = nil,
        toolchainSummary: String? = nil,
        appSummary: String? = nil,
        briefing: String? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.scheme = scheme
        self.packageIdentifier = packageIdentifier
        self.version = version
        self.files = files
        self.buildSummary = buildSummary
        self.toolchainSummary = toolchainSummary
        self.appSummary = appSummary
        self.briefing = briefing
    }
}

/// Builds what the model is told: a system prompt that knows what a Theos project
/// is, and a context block with the project's own files.
///
/// The prompt is the part that decides whether the assistant writes a buildable
/// tweak or plausible-looking Objective-C that hooks a class that does not exist.
/// It is a pure function of the project so it can be reviewed and tested like
/// anything else.
public enum AgentContext {

    /// Which files matter most. The Logos source is the reason the project
    /// exists; the Makefile and control decide whether it builds and installs.
    public static func relevance(of path: String) -> Int {
        let lower = path.lowercased()
        let name = (path as NSString).lastPathComponent

        if path.hasPrefix("packages/") || path.hasPrefix(".theos/") || path.hasPrefix("obj/") { return 90 }
        if lower.hasSuffix(".x") || lower.hasSuffix(".xm") { return 0 }
        if name == "Makefile" { return 1 }
        if name == "control" { return 1 }
        if lower.hasSuffix(".plist") && !path.contains("/Resources/") { return 2 }
        if lower.hasSuffix(".h") || lower.hasSuffix(".m") || lower.hasSuffix(".mm") || lower.hasSuffix(".swift") { return 3 }
        if lower.hasSuffix(".plist") { return 4 }
        if name == "README.md" { return 8 }
        return 6
    }

    /// The project's files, most relevant first, cut to a character budget.
    public static func fileDigest(_ files: [ProjectFile], budget: Int) -> String {
        let ordered = files.sorted { lhs, rhs in
            let left = relevance(of: lhs.path)
            let right = relevance(of: rhs.path)
            if left != right { return left < right }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }

        var output = ""
        var omitted: [String] = []
        for file in ordered {
            guard relevance(of: file.path) < 90 else { continue }
            let header = "### \(file.path) (\(file.contents.utf8.count) bytes)\n"
            let remaining = budget - output.utf8.count
            if remaining < header.utf8.count + 200 {
                omitted.append(file.path)
                continue
            }
            var body = file.contents.normalisedLineEndings()
            let allowance = remaining - header.utf8.count
            if body.utf8.count > allowance {
                // Cut on a line boundary so the model is not handed half a statement.
                let clipped = String(body.prefix(allowance))
                if let lastNewline = clipped.lastIndex(of: "\n") {
                    body = String(clipped[clipped.startIndex..<lastNewline])
                } else {
                    body = clipped
                }
                body += "\n… (truncated — read the rest with read_file)"
            }
            output += header + body
            if !output.hasSuffix("\n") { output += "\n" }
            output += "\n"
        }

        if !omitted.isEmpty {
            output += "… \(omitted.count) more file\(omitted.count == 1 ? "" : "s") not shown: \(omitted.joined(separator: ", "))\n"
        }
        return output
    }

    /// The message that carries the project with every user turn.
    ///
    /// `namesOnly` sends the file list without the contents: the agent then reads
    /// what it needs, which is smaller and keeps more of the project on the
    /// device. The default sends the files, because a tweak is five small files
    /// and it saves a round trip each.
    public static func contextMessage(
        _ snapshot: AgentProjectSnapshot,
        mode: AgentContextMode = .fullFiles,
        budget: Int = 60_000
    ) -> String {
        var lines: [String] = []
        lines.append("# Project: \(snapshot.name)")
        var facts: [String] = []
        if let kind = snapshot.kind { facts.append(kind.displayName) }
        facts.append("packaging: \(snapshot.scheme.displayName), installs under \(snapshot.scheme.installRootDescription), Architecture: \(snapshot.scheme.debianArchitecture)")
        if let identifier = snapshot.packageIdentifier { facts.append("package id: \(identifier)") }
        if let version = snapshot.version { facts.append("version: \(version)") }
        facts.append("root: \(snapshot.path)")
        lines.append(facts.joined(separator: "\n"))
        lines.append("")

        if let toolchain = snapshot.toolchainSummary {
            lines.append("## This device")
            lines.append(toolchain)
            lines.append("")
        }

        if let app = snapshot.appSummary {
            lines.append("## TheosStudio workspace")
            lines.append(app)
            lines.append("")
        }

        if let build = snapshot.buildSummary {
            lines.append("## Last build")
            lines.append(build)
            lines.append("")
        } else {
            lines.append("## Last build")
            lines.append("No build has run in this session. Call build before claiming anything compiles.")
            lines.append("")
        }

        lines.append("## Files")
        switch mode {
        case .fullFiles:
            lines.append(fileDigest(snapshot.files, budget: budget))
        case .namesOnly:
            let ordered = snapshot.files
                .filter { relevance(of: $0.path) < 90 }
                .sorted { lhs, rhs in
                    let left = relevance(of: lhs.path)
                    let right = relevance(of: rhs.path)
                    if left != right { return left < right }
                    return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                }
            for file in ordered {
                lines.append("- \(file.path) (\(file.contents.utf8.count) bytes)")
            }
            lines.append("")
            lines.append("The contents are not included. Use read_file to read what you need — start with the Makefile and the Logos source.")
        }
        return lines.joined(separator: "\n")
    }

    public static func systemPrompt(
        _ snapshot: AgentProjectSnapshot,
        preferences: Set<AgentPreference> = []
    ) -> String {
        let name = snapshot.name
        let scheme = snapshot.scheme

        var prompt = """
        You are the build assistant inside TheosStudio, an app that writes, builds and installs \
        Theos tweaks on a jailbroken iPhone. The user is a tweak developer; you are paired with \
        them on one project at a time.

        # The project
        "\(name)" is a Theos project at \(snapshot.path). Its files are listed in the context \
        message below. Everything you touch lives in that directory.

        # How a Theos project fits together

        - **Makefile** holds `TWEAK_NAME` (or `APPLICATION_NAME`/`TOOL_NAME`/`BUNDLE_NAME`), the \
        source list (`\(name)_FILES`), `ARCHS`, `TARGET`, and the packaging scheme. A source file \
        that is not in the file list is never compiled — adding a file means adding it there too.
        - **\(name).plist** is the injection filter. Its file name must equal `TWEAK_NAME` exactly. \
        It decides which processes load the dylib: keep it narrow (one bundle identifier). \
        A filter that matches everything causes bootloops and battery drain.
        - **control** is the Debian metadata. Theos overwrites `Architecture:` at package time. \
        `Version:` must change or dpkg will not install an upgrade. A tweak needs a hooking \
        library in `Depends:` — `mobilesubstrate` (which ElleKit provides) or `ellekit`.
        - **Logos sources** (`.x`, `.xm`) are ordinary Objective-C with `%` directives. The rules \
        that decide whether the result works:
          - `%hook Class` … `%end` replaces methods at runtime. A hook for a class or selector \
        that does not exist on this iOS version does **not** fail — it silently never fires. \
        Never assume a private class name; say so if you could not confirm it.
          - `%orig` calls the original implementation. A non-void hook must return a value. \
        `%orig(newArgument)` changes an argument before the original runs.
          - Put version-specific hooks in a `%group` and install it with `%init()` behind \
        `@available`, so a missing class cannot break the hooks that do exist.
          - `%c(ClassName)` returns the class at runtime, nil when it is absent: prefer it to \
        `NSClassFromString`.
          - `%property`, `%new` and `%subclass` add members; prefix new names to avoid collisions.
        - **Preferences** are read with `CFPreferencesCopyAppValue` from the package's own domain \
        and re-read when the settings bundle posts a Darwin notification, so a change does not \
        need a respring.

        # Packaging, for this project

        The scheme is **\(scheme.displayName)**: files install under `\(scheme.installRootDescription)` \
        and `Architecture:` is `\(scheme.debianArchitecture)`. \(scheme.summary)

        Code that opens a file at runtime gets no path rewriting from Theos, so a rootless package \
        must build its own paths — never hardcode `/Library` or `/usr`. Under roothide there is no \
        fixed prefix at all: it is resolved per boot, which is what `jbroot()` is for.

        # The user's briefing for this project

        __BRIEFING__

        # How to work

        1. **Read before writing.** The files are below; use `read_file` for anything else you need.
        2. **Change as little as possible.** `replace_in_file` for an edit (its `find` must match \
        the file exactly, once); `write_file` for a new file or a deliberate rewrite.
        3. **Build after every change worth verifying**, then read the diagnostics instead of \
        guessing what the compiler will say.
        4. **Say what you could not verify.** A hook whose class you could not confirm is a guess, \
        and the user needs to know that.
        5. **Never guess a private class or method name.** `search_headers` searches the SDK \
        headers and the user's header dump: use it to confirm the name before you write the hook, \
        because a hook for a class that does not exist silently never fires.
        6. **When a tweak crashes the process it hooks**, `read_crashes` says whether this project's \
        dylib was on the stack. That is the difference between guessing and knowing.
        7. **Before a change worth committing**, `git_status` and `git_diff` show what has already \
        moved, including edits the user made by hand.

        # Rules

        - Paths are relative to the project root. Absolute paths and `..` are refused by the app.
        - Every file change and every build is shown to the user, who approves it before it runs. \
        Do not describe a change as done until the tool result says it happened.
        - Never claim the project compiles without calling `build`.
        - Only call `install` when the user asked for the tweak to be installed.
        - End the turn by calling `finish` with a summary: what changed, what you checked, and \
        what the user should do next.
        """

        let preferenceLines = AgentPreference.promptLines(for: preferences)
        if !preferenceLines.isEmpty {
            prompt += "\n\n# Standing instructions\n\n"
            prompt += preferenceLines.map { "- " + $0 }.joined(separator: "\n")
        }

        // A briefing goes in where the user can see it is theirs, or is removed
        // entirely so the prompt does not carry an empty heading.
        if let briefing = snapshot.briefing?.trimmingCharacters(in: .whitespacesAndNewlines), !briefing.isEmpty {
            prompt = prompt.replacingOccurrences(of: "__BRIEFING__", with: briefing)
        } else if let range = prompt.range(of: "# The user's briefing for this project") {
            let end = prompt.range(of: "# How to work")?.lowerBound ?? prompt.endIndex
            prompt.removeSubrange(range.lowerBound..<end)
        }

        if let kind = snapshot.kind, kind.needsHookingLibrary {
            prompt += "\n\nThis project is a \(kind.displayName.lowercased()): its package must depend on a hooking library, or it installs and does nothing."
        }
        if let kind = snapshot.kind, kind == .tool || kind == .application {
            prompt += "\n\nThis project is not a tweak: it is installed as \(kind == .application ? "an app in /Applications" : "an executable in /usr/local/bin") and nothing injects it."
        }
        return prompt
    }
}
