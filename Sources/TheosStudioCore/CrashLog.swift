import Foundation

/// What a crash log says, reduced to what is worth reading on a phone.
///
/// A tweak that crashes SpringBoard produces a crash log, and the useful part of
/// a 200 KB `.ips` is four lines: which process, when, why, and whether our dylib
/// was in the stack. The app shows those, sorts our own crashes to the top, and
/// hands the whole file to the assistant when asked.
public struct CrashLogSummary: Equatable, Sendable, Identifiable {
    public var path: String
    /// The process that died, e.g. `SpringBoard`.
    public var process: String
    public var date: Date?
    public var kind: String?
    public var reason: String?
    /// The first frame that mentions one of the names we were asked about.
    public var ownFrame: String?
    /// True when the crash mentions this project's dylib or package.
    public var mentionsOurs: Bool

    public var id: String { path }

    public var title: String {
        if let date {
            return "\(process) — \(Self.formatter.string(from: date))"
        }
        return process
    }

    public static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Reads the two formats a device produces.
///
/// Modern iOS writes `.ips`: a one-line JSON header followed by the report. Older
/// jailbreaks and some tools write the classic `.crash` text. Both are read here,
/// because which one you have depends on the iOS version, not on the tweak.
public enum CrashLogParser {

    /// Where crash logs live, rootless first.
    public static func candidateDirectories(jailbreak: JailbreakLayout, home: String) -> [String] {
        var directories: [String] = []
        if let prefix = jailbreak.rootlessPrefix {
            directories.append("\(prefix)/var/mobile/Library/Logs/CrashReporter")
        }
        directories.append("/var/mobile/Library/Logs/CrashReporter")
        directories.append(home + "/Library/Logs/CrashReporter")
        // Newer iOS splits them further.
        directories += directories.filter { $0.hasPrefix("/") }.map { $0 + "/DiagnosticLogs" }
        return directories
    }

    public static func parse(fileName: String, contents: String, interestingNames: [String]) -> CrashLogSummary {
        let names = interestingNames.filter { !$0.isEmpty }
        let isModern = contents.hasPrefix("{")

        var summary = CrashLogSummary(
            path: fileName,
            process: processFromFileName(fileName),
            date: dateFromFileName(fileName),
            kind: nil,
            reason: nil,
            ownFrame: nil,
            mentionsOurs: false
        )

        if isModern {
            parseModern(contents, into: &summary)
        } else {
            parseLegacy(contents, into: &summary)
        }

        if summary.process.isEmpty {
            summary.process = "Unknown process"
        }

        for name in names where contents.contains(name) {
            summary.mentionsOurs = true
            if summary.ownFrame == nil, let frame = firstFrame(mentioning: name, in: contents) {
                summary.ownFrame = frame
            }
        }
        return summary
    }

    // MARK: - Modern (.ips)

    private static func parseModern(_ contents: String, into summary: inout CrashLogSummary) {
        if let header = firstJSONObject(in: contents) {
            if let name = header["app_name"] as? String { summary.process = name }
            if let process = header["process"] as? String { summary.process = process }
            if let bugType = header["bug_type"] as? String { summary.kind = "bug type \(bugType)" }
            if let timestamp = header["timestamp"] as? String {
                summary.date = isoFormatter.date(from: timestamp) ?? summary.date
            }
        }

        summary.reason = firstMatch(
            patterns: [
                "\"termination\"\\s*:\\s*\\{[^}]*\"indicator\"\\s*:\\s*\"([^\"]+)\"",
                "\"terminationReason\"\\s*:\\s*\"([^\"]+)\"",
                "\"exception\"\\s*:\\s*\\{[^}]*\"type\"\\s*:\\s*\"([^\"]+)\"",
                "\"type\"\\s*:\\s*\"(EXC_[A-Z_]+)\"",
                "\"bug_type\"\\s*:\\s*\"([0-9]+)\"",
            ],
            in: contents
        ).map { $0.replacingOccurrences(of: "\\n", with: " ") }

        if summary.reason == nil {
            summary.reason = firstMatch(patterns: ["\"termination\"[^\\n]{0,200}"], in: contents)
        }
    }

    // MARK: - Legacy (.crash)

    private static func parseLegacy(_ contents: String, into summary: inout CrashLogSummary) {
        if let process = firstMatch(patterns: ["^Process:\\s*(?:\\[([^\\]]+)\\]\\s*)?([^\\n\\[]+)"], in: contents) {
            summary.process = process.trimmingCharacters(in: .whitespaces)
        }
        if let type = firstMatch(patterns: ["^Exception Type:\\s*(.+)$"], in: contents) {
            summary.kind = type.trimmingCharacters(in: .whitespaces)
        }
        summary.reason = firstMatch(patterns: ["^Termination Reason:\\s*(.+)$"], in: contents)
            ?? firstMatch(patterns: ["^Crashed Thread:\\s*(.+)$"], in: contents)
    }

    // MARK: - Names

    private static func processFromFileName(_ fileName: String) -> String {
        let base = (fileName as NSString).lastPathComponent
        for prefix in ["-", "_"] {
            if let range = base.range(of: prefix), base.distance(from: base.startIndex, to: range.lowerBound) > 0 {
                return String(base[base.startIndex..<range.lowerBound])
            }
        }
        return (base as NSString).deletingPathExtension
    }

    private static func dateFromFileName(_ fileName: String) -> Date? {
        // e.g. SpringBoard-2026-10-01-120000.ips — the whole match, not a group.
        let base = (fileName as NSString).lastPathComponent
        guard let regex = try? NSRegularExpression(pattern: "[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}"),
              let match = regex.firstMatch(in: base, options: [], range: NSRange(base.startIndex..<base.endIndex, in: base)),
              let range = Range(match.range, in: base) else { return nil }

        let digits = String(base[range]).filter(\.isNumber)
        guard digits.count == 14 else { return nil }
        let values = digits.map { Int(String($0)) ?? 0 }
        var components = DateComponents()
        components.year = values[0] * 1000 + values[1] * 100 + values[2] * 10 + values[3]
        components.month = values[4] * 10 + values[5]
        components.day = values[6] * 10 + values[7]
        components.hour = values[8] * 10 + values[9]
        components.minute = values[10] * 10 + values[11]
        components.second = values[12] * 10 + values[13]
        return Calendar.current.date(from: components)
    }

    /// The first stack frame mentioning a name, as a printable line.
    static func firstFrame(mentioning name: String, in contents: String) -> String? {
        for line in contents.split(separator: "\n") where line.contains(name) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Frames read like `0x0000 MyTweak.dylib + 42` or `12 MyTweak 0x...`.
            if trimmed.contains("0x") || trimmed.range(of: "^[0-9]+ +", options: .regularExpression) != nil {
                return trimmed
            }
        }
        return firstMatch(patterns: ["[^\\n]{0,40}\\" + NSRegularExpression.escapedPattern(for: name) + "[^\\n]{0,40}"], in: contents)?
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Small helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The first line of an `.ips` is a small JSON object.
    static func firstJSONObject(in contents: String) -> [String: Any]? {
        guard let newline = contents.firstIndex(of: "\n") else { return nil }
        let header = String(contents[contents.startIndex..<newline])
        guard let data = header.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    static func firstMatch(patterns: [String], in contents: String, options: NSRegularExpression.Options = [.anchorsMatchLines]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
            guard let match = regex.firstMatch(in: contents, options: [], range: range) else { continue }
            // A capture group wins over the whole match.
            let groupIndex = match.numberOfRanges > 1 ? 1 : 0
            guard let capture = Range(match.range(at: groupIndex), in: contents) else { continue }
            let value = String(contents[capture])
            if !value.isEmpty { return value }
        }
        return nil
    }
}
