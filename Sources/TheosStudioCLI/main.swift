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
      --final               FINALPACKAGE=1 (optimised, stripped)
      --clean               clean first
      --jobs <n>            parallel make
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
    let request = BuildRequest(
        projectPath: (project as NSString).expandingTildeInPath,
        scheme: scheme,
        finalPackage: flag("--final", in: rest),
        cleanFirst: flag("--clean", in: rest),
        verbose: true,
        jobs: option("--jobs", in: rest).flatMap(Int.init)
    )
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
