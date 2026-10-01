import Foundation

public struct ProjectHealthIssue: Equatable, Sendable, Identifiable {
    public enum Severity: String, Sendable { case error, warning, note }
    public let severity: Severity
    public let message: String
    public let path: String?

    public init(_ severity: Severity, _ message: String, path: String? = nil) {
        self.severity = severity
        self.message = message
        self.path = path
    }

    public var id: String { "\(severity.rawValue)|\(path ?? "")|\(message)" }
}

public enum ProjectHealth {
    public static func inspect(files: [ProjectFile]) -> [ProjectHealthIssue] {
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.contents) })
        let makefile = byPath["Makefile"] ?? ""
        let controlText = byPath["control"] ?? ""
        var issues: [ProjectHealthIssue] = []

        if makefile.isEmpty { issues.append(.init(.error, "Makefile is missing or empty.", path: "Makefile")) }
        if controlText.isEmpty { issues.append(.init(.error, "control is missing or empty.", path: "control")) }

        if !controlText.isEmpty {
            let control = ControlFile.parse(controlText)
            let manifest = ProjectManifest.parse(makefile: makefile, control: controlText)
            for issue in ControlValidator.issues(for: control, kind: manifest.kind, projectName: manifest.name) {
                issues.append(.init(issue.severity == .error ? .error : .warning, issue.message, path: "control"))
            }
        }

        if !makefile.isEmpty {
            let declared = Set(MakefileEditor.sources(in: makefile))
            let existing = Set(files.map(\.path))
            for source in declared.sorted() where !existing.contains(source) {
                issues.append(.init(.error, "Makefile references '\(source)', but that source file does not exist.", path: "Makefile"))
            }

            let sourceFiles = files.map(\.path).filter(MakefileEditor.isSourceFile)
            for source in sourceFiles.sorted() where !declared.contains(source) {
                issues.append(.init(.warning, "'\(source)' is a source file but is not listed in the Makefile.", path: source))
            }
        }

        if files.contains(where: { $0.path.hasPrefix(".theos/") }) {
            issues.append(.init(.note, ".theos build products are present; clean them when diagnosing stale builds."))
        }
        if files.contains(where: { $0.path.hasPrefix("packages/") && $0.path.hasSuffix(".deb") }) {
            issues.append(.init(.note, "Built packages are present in packages/."))
        }

        return issues.sorted { a, b in
            func rank(_ s: ProjectHealthIssue.Severity) -> Int { s == .error ? 0 : (s == .warning ? 1 : 2) }
            if rank(a.severity) != rank(b.severity) { return rank(a.severity) < rank(b.severity) }
            return (a.path ?? "").localizedStandardCompare(b.path ?? "") == .orderedAscending
        }
    }
}
