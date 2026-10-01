import Foundation

/// One compiler message lifted out of the build log.
public struct CompilerDiagnostic: Equatable, Sendable {
    public enum Severity: String, Sendable {
        case error
        case warning
        case note

        var rank: Int {
            switch self {
            case .error: return 0
            case .warning: return 1
            case .note: return 2
            }
        }
    }

    public var file: String?
    public var line: Int?
    public var column: Int?
    public var severity: Severity
    public var message: String
    /// The original log line, so the console can still show it verbatim.
    public var raw: String

    public init(
        file: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        severity: Severity,
        message: String,
        raw: String
    ) {
        self.file = file
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
        self.raw = raw
    }

    /// `Tweak.x:12:5` — what a compiler prints, without the message.
    public var location: String? {
        guard let file else { return nil }
        var text = file
        if let line {
            text += ":\(line)"
            if let column { text += ":\(column)" }
        }
        return text
    }
}

/// Turns the raw log into the few things the app shows in a summary: how many
/// errors and warnings, the line that actually stopped the build, and the path of
/// the .deb if packaging got that far.
public enum DiagnosticParser {

    private static let fourPart = try? NSRegularExpression(
        pattern: "^(.*?):(\\d+):(\\d+):\\s*(fatal error|error|warning|note):\\s*(.*)$"
    )
    private static let threePart = try? NSRegularExpression(
        pattern: "^(.*?):(\\d+):\\s*(fatal error|error|warning|note):\\s*(.*)$"
    )
    private static let bareSeverity = try? NSRegularExpression(
        pattern: "^(fatal error|error|warning|note):\\s*(.*)$"
    )
    private static let packagePath = try? NSRegularExpression(
        pattern: "building package .* in '([^']+)'"
    )
    private static let makeFailure = try? NSRegularExpression(
        pattern: "^make(\\[\\d+\\])?: \\*\\*\\* "
    )

    public static func diagnostic(fromLine line: String) -> CompilerDiagnostic? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        if let regex = fourPart, let match = regex.firstMatch(in: text, options: [], range: range),
           let fileRange = Range(match.range(at: 1), in: text),
           let lineRange = Range(match.range(at: 2), in: text),
           let columnRange = Range(match.range(at: 3), in: text),
           let severityRange = Range(match.range(at: 4), in: text),
           let messageRange = Range(match.range(at: 5), in: text) {
            return CompilerDiagnostic(
                file: String(text[fileRange]),
                line: Int(text[lineRange]),
                column: Int(text[columnRange]),
                severity: severity(from: String(text[severityRange])),
                message: String(text[messageRange]),
                raw: line
            )
        }

        if let regex = threePart, let match = regex.firstMatch(in: text, options: [], range: range),
           let fileRange = Range(match.range(at: 1), in: text),
           let lineRange = Range(match.range(at: 2), in: text),
           let severityRange = Range(match.range(at: 3), in: text),
           let messageRange = Range(match.range(at: 4), in: text) {
            return CompilerDiagnostic(
                file: String(text[fileRange]),
                line: Int(text[lineRange]),
                severity: severity(from: String(text[severityRange])),
                message: String(text[messageRange]),
                raw: line
            )
        }

        if let regex = bareSeverity, let match = regex.firstMatch(in: text, options: [], range: range),
           let severityRange = Range(match.range(at: 1), in: text),
           let messageRange = Range(match.range(at: 2), in: text) {
            return CompilerDiagnostic(
                severity: severity(from: String(text[severityRange])),
                message: String(text[messageRange]),
                raw: line
            )
        }
        return nil
    }

    private static func severity(from text: String) -> CompilerDiagnostic.Severity {
        switch text {
        case "warning": return .warning
        case "note": return .note
        default: return .error
        }
    }

    /// Distinct diagnostics, errors first. Compilers repeat the same message for
    /// every architecture they build, so duplicates are the norm, not the
    /// exception.
    public static func diagnostics(in lines: [String]) -> [CompilerDiagnostic] {
        var seen = Set<String>()
        var result: [CompilerDiagnostic] = []
        for line in lines {
            guard let diagnostic = diagnostic(fromLine: line) else { continue }
            let key = "\(diagnostic.severity.rawValue)|\(diagnostic.location ?? "")|\(diagnostic.message)"
            guard seen.insert(key).inserted else { continue }
            result.append(diagnostic)
        }
        return result.sorted { lhs, rhs in
            if lhs.severity.rank != rhs.severity.rank { return lhs.severity.rank < rhs.severity.rank }
            return (lhs.location ?? "") < (rhs.location ?? "")
        }
    }

    /// The path dpkg-deb reported it wrote, which is the .deb the build produced.
    public static func packagedFile(in lines: [String]) -> String? {
        for line in lines.reversed() {
            guard let regex = packagePath else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, options: [], range: range),
                  let pathRange = Range(match.range(at: 1), in: line) else { continue }
            return String(line[pathRange])
        }
        return nil
    }

    /// The last `make: *** ...` line: the message that says why the build stopped.
    public static func fatalLine(in lines: [String]) -> String? {
        for line in lines.reversed() {
            guard let regex = makeFailure else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
