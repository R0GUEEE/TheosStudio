import Foundation
import TheosStudioCore

// A small front end for the engine. It exists so the same code the app runs can
// be exercised from a terminal, on the device (where it can scaffold and build a
// project without the UI) and in CI (where the smoke test runs it).

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let rest = Array(arguments.dropFirst())

func printUsage() {
    print("""
    theosstudio — Theos project tooling, usable without the app

    usage:
      theosstudio env [--theos PATH]         what this device can build with
      theosstudio new <kind> <Name> [opts]   scaffold a project
      theosstudio plan <project> [opts]      print the make command a build runs
      theosstudio lint <project>             control file problems, if any
      theosstudio doctor <project>           whole-project health scan
      theosstudio search <project> <query>   search all text files
      theosstudio stats <project>            project size / language metrics
      theosstudio bump <project> <part>      bump control Version (major/minor/patch/build)
      theosstudio profiles                   list built-in build profiles
      theosstudio doctors <project>          alias of lint
      theosstudio help

    kinds:
      \(ProjectKind.allCases.map(\.rawValue).joined(separator: ", "))

    options for `new`:
      --dir <path>          where to create the project (default: ./<Name>)
      --scheme <scheme>     \(PackagingScheme.allCases.map(\.rawValue).joined(separator: " | ")) (default: detected)
      --identifier <id>     reverse-DNS package id (default: com.example.<name>)
      --author <name>       Maintainer name
      --email <address>     Maintainer address
      --bundle <bundle id>  process a tweak injects into (default: com.apple.springboard)
      --ios <version>       minimum iOS version (default: 15.0)

    options for `plan`:
      --scheme <scheme>     override the packaging scheme
      --profile <name>      debug | fast | release | rebuild
      --final               FINALPACKAGE=1 (optimised, stripped)
      --clean               clean first
      --jobs <n>            parallel make

    options for `search`:
      --regex               treat the query as a regular expression
      --case                case-sensitive matching
      --whole-word          only match complete words
      --ext <csv>           restrict to file extensions, e.g. x,xm,m,swift
    """)
}

/// True when a file exists at `path`.
func fileExists(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return exists && !isDirectory.boolValue
}

func directoryExists(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
}

func listDirectory(_ path: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
}

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func flag(_ name: String, in arguments: [String]) -> Bool {
    arguments.contains(name)
}

func projectTextFiles(at root: String) -> [ProjectFile] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: root) else { return [] }
    var result: [ProjectFile] = []
    while let relative = enumerator.nextObject() as? String {
        let components = relative.split(separator: "/").map(String.init)
        if components.contains(where: { ProjectFiles.hiddenDirectoryNames.contains($0) }) {
            continue
        }
        let full = root + "/" + relative
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
        guard let data = fm.contents(atPath: full), data.count <= 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { continue }
        result.append(ProjectFile(path: relative, contents: text))
    }
    return result
}


let home = NSHomeDirectory()
let jailbreak = JailbreakLayout.detect(exists: directoryExists)

switch command {
case "env":
    let report = TheosLocator.report(
        home: home,
        override: option("--theos", in: rest),
        jailbreak: jailbreak,
        exists: fileExists,
        listDirectory: listDirectory
    )
    print("jailbreak:      \(jailbreak.scheme.displayName)\(jailbreak.rootlessPrefix.map { " (\($0))" } ?? "")")
    print("theos:          \(report.theosRoot ?? "not found")\(report.theosRootWasOverridden ? " (from --theos)" : "")")
    print("sdks:           \(report.sdkDirectories.isEmpty ? "none" : report.sdkDirectories.joined(separator: ", "))")
    print("ready to build: \(report.isReadyToBuild ? "yes" : "no")")
    print("tools:")
    for status in report.statuses {
        let mark = status.isInstalled ? "ok  " : (status.tool.required ? "MISS" : "opt ")
        print("  [\(mark)] \(status.tool.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(status.path ?? status.tool.purpose)")
    }
    if !report.notes.isEmpty {
        print("notes:")
        for note in report.notes { print("  - \(note)") }
    }
    if !report.installCommand.isEmpty {
        print("to fix: \(report.installCommand)")
    }

case "new":
    guard rest.count >= 2, let kind = ProjectKind(rawValue: rest[0]) else {
        FileHandle.standardError.write(Data("usage: theosstudio new <kind> <Name>\n".utf8))
        exit(64)
    }
    let name = ProjectNaming.sanitize(rest[1])
    let scheme = option("--scheme", in: rest).flatMap(PackagingScheme.init(rawValue:)) ?? jailbreak.scheme
    let directory = option("--dir", in: rest) ?? (FileManager.default.currentDirectoryPath + "/" + name)
    let request = TemplateRequest(
        name: name,
        kind: kind,
        scheme: scheme,
        packageIdentifier: option("--identifier", in: rest) ?? ProjectNaming.defaultPackageIdentifier(name: name),
        authorName: option("--author", in: rest) ?? "Your Name",
        authorEmail: option("--email", in: rest) ?? "you@example.com",
        minimumIOSVersion: option("--ios", in: rest) ?? "15.0",
        injectionBundle: option("--bundle", in: rest) ?? "com.apple.springboard"
    )

    let files = ProjectTemplate.files(for: request)
    for file in files {
        let path = directory + "/" + file.path
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try file.contents.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("failed to write \(file.path): \(error)\n".utf8))
            exit(74)
        }
        print("wrote \(file.path)")
    }
    print("\n\(name) created in \(directory)")
    print("build it with: theosstudio plan '\(directory)'")

case "plan":
    guard let project = rest.first else {
        FileHandle.standardError.write(Data("usage: theosstudio plan <project>\n".utf8))
        exit(64)
    }
    let report = TheosLocator.report(
        home: home, override: nil, jailbreak: jailbreak, exists: fileExists, listDirectory: listDirectory
    )
    let scheme = option("--scheme", in: rest).flatMap(PackagingScheme.init(rawValue:)) ?? jailbreak.scheme
    var request = BuildRequest(
        projectPath: (project as NSString).expandingTildeInPath,
        scheme: scheme,
        finalPackage: flag("--final", in: rest),
        cleanFirst: flag("--clean", in: rest),
        verbose: true,
        jobs: option("--jobs", in: rest).flatMap(Int.init)
    )
    if let profileName = option("--profile", in: rest), let profile = BuildProfile(rawValue: profileName) {
        request = profile.applying(to: request)
    }
    let environment = report.theosRoot.map {
        TheosLocator.environment(theosRoot: $0, binDirectories: report.binDirectories, base: [:], home: home)
    } ?? [:]
    let makePath = report.status(for: "make")?.path ?? "make"
    for planned in BuildPlanner.plan(for: request, make: makePath, environment: environment) {
        print(planned.display)
        print("  PATH=\(environment["PATH"] ?? "unset")")
    }
    if !report.isReadyToBuild {
        FileHandle.standardError.write(Data("warning: this device is not ready to build (see: theosstudio env)\n".utf8))
    }


case "doctor":
    guard let project = rest.first else {
        FileHandle.standardError.write(Data("usage: theosstudio doctor <project>\n".utf8))
        exit(64)
    }
    let root = (project as NSString).expandingTildeInPath
    let files = projectTextFiles(at: root)
    let issues = ProjectHealth.inspect(files: files)
    if issues.isEmpty {
        print("healthy: no project-level problems found")
    } else {
        for issue in issues {
            let location = issue.path.map { " [\($0)]" } ?? ""
            print("\(issue.severity.rawValue):\(location) \(issue.message)")
        }
        if issues.contains(where: { $0.severity == .error }) { exit(1) }
    }

case "search":
    guard rest.count >= 2 else {
        FileHandle.standardError.write(Data("usage: theosstudio search <project> <query>\n".utf8))
        exit(64)
    }
    let root = (rest[0] as NSString).expandingTildeInPath
    let extensions = Set((option("--ext", in: rest) ?? "").split(separator: ",").map(String.init))
    let options = ProjectSearchOptions(
        caseSensitive: flag("--case", in: rest),
        useRegex: flag("--regex", in: rest),
        wholeWord: flag("--whole-word", in: rest),
        fileExtensions: extensions
    )
    for match in AdvancedProjectSearch.search(query: rest[1], files: projectTextFiles(at: root), options: options) {
        print("\(match.path):\(match.line):\(match.column): \(match.preview)")
    }

case "stats":
    guard let project = rest.first else {
        FileHandle.standardError.write(Data("usage: theosstudio stats <project>\n".utf8))
        exit(64)
    }
    let root = (project as NSString).expandingTildeInPath
    let metrics = ProjectMetrics.calculate(files: projectTextFiles(at: root))
    print("files:      \(metrics.fileCount)")
    print("lines:      \(metrics.lineCount)")
    print("non-blank:  \(metrics.nonBlankLineCount)")
    print("text bytes: \(metrics.bytes)")
    for key in metrics.languages.keys.sorted() {
        print("  \(key): \(metrics.languages[key] ?? 0)")
    }

case "bump":
    guard rest.count >= 2, let part = VersionBumper.Part(rawValue: rest[1]) else {
        FileHandle.standardError.write(Data("usage: theosstudio bump <project> <major|minor|patch|build>\n".utf8))
        exit(64)
    }
    let root = (rest[0] as NSString).expandingTildeInPath
    let path = root + "/control"
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(Data("could not read \(path)\n".utf8))
        exit(66)
    }
    let updated = VersionBumper.updatingControl(source, part: part)
    do {
        try updated.write(toFile: path, atomically: true, encoding: .utf8)
        print(ControlFile.parse(updated).version ?? "updated")
    } catch {
        FileHandle.standardError.write(Data("failed to write \(path): \(error)\n".utf8))
        exit(74)
    }

case "profiles":
    for profile in BuildProfile.allCases {
        print("\(profile.rawValue)\t\(profile.displayName)")
    }

case "lint", "doctors":
    guard let project = rest.first else {
        FileHandle.standardError.write(Data("usage: theosstudio lint <project>\n".utf8))
        exit(64)
    }
    let root = (project as NSString).expandingTildeInPath
    let controlText = (try? String(contentsOfFile: root + "/control", encoding: .utf8)) ?? ""
    let makefileText = (try? String(contentsOfFile: root + "/Makefile", encoding: .utf8)) ?? ""
    guard !controlText.isEmpty || !makefileText.isEmpty else {
        FileHandle.standardError.write(Data("\(root) does not look like a Theos project (no control, no Makefile)\n".utf8))
        exit(66)
    }
    let manifest = ProjectManifest.parse(makefile: makefileText, control: controlText)
    let issues = ControlValidator.issues(
        for: ControlFile.parse(controlText),
        kind: manifest.kind,
        projectName: manifest.name
    )
    if issues.isEmpty {
        print("no problems found in \(root)")
    } else {
        for issue in issues {
            print("\(issue.severity.rawValue): \(issue.message)")
        }
        if issues.contains(where: { $0.severity == .error }) { exit(1) }
    }

case "help", "-h", "--help":
    printUsage()

default:
    FileHandle.standardError.write(Data("unknown command '\(command)'\n".utf8))
    printUsage()
    exit(64)
}
