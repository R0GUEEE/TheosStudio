import Foundation

/// Reading a device log.
///
/// The other half of debugging a tweak: a crash log says the tweak fell over, and
/// the system log says what it was doing just before. Whether a device keeps one
/// depends on the bootstrap — some run `syslogd`, some do not — so this looks in
/// the places a jailbroken device puts one and says so plainly when there is
/// nothing to read.
public enum DeviceLogs {

    /// Where a bootstrap keeps its log, rootless first.
    public static func candidatePaths(jailbreak: JailbreakLayout, home: String) -> [String] {
        var paths: [String] = []
        if let prefix = jailbreak.rootlessPrefix {
            paths.append("\(prefix)/var/log/syslog")
            paths.append("\(prefix)/var/log/system.log")
        }
        paths.append("/var/log/syslog")
        paths.append("/var/log/system.log")
        paths.append(home + "/Library/Logs/syslog")
        return paths
    }

    /// The last `count` lines, which is the part of a log anyone wants.
    public static func tail(_ text: String, lines count: Int) -> [String] {
        let all = text.normalisedLineEndings()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard all.count > count else { return all }
        return Array(all.suffix(count))
    }

    /// Lines matching a query, newest last. Case-insensitive, because nobody
    /// remembers how `NSLog` capitalised their tag.
    public static func lines(in text: String, matching query: String, limit: Int = 400) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let candidates = text.normalisedLineEndings()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !needle.isEmpty else {
            return candidates.count > limit ? Array(candidates.suffix(limit)) : candidates
        }
        return Array(candidates.filter { $0.range(of: needle, options: .caseInsensitive) != nil }.suffix(limit))
    }

    /// A tweak's log lines are the ones that mention it: its own `NSLog` tag, or
    /// the package it came from.
    public static func searchTerms(name: String, packageIdentifier: String? = nil) -> [String] {
        guard !name.isEmpty else { return [] }
        var terms = ["[\(name)]", name]
        if let packageIdentifier, !packageIdentifier.isEmpty {
            terms.append(packageIdentifier)
        }
        return terms
    }

    /// What to filter by when nothing has been typed: the tag the tweak's own
    /// `NSLog` lines carry.
    public static func defaultQuery(name: String) -> String {
        name.isEmpty ? "" : "[\(name)]"
    }
}

/// What `dpkg --dry-run -i` had to say.
///
/// Installing a package is the one action in the app that can leave the device
/// worse than it found it, and dpkg already knows what it would do: which version
/// this replaces, what it conflicts with, and whether the dependencies are there.
/// That is worth reading *before* the install rather than after.
public struct InstallPreview: Equatable, Sendable {
    /// `com.example.mytweak (0.0.1)`
    public var package: String?
    /// The version being replaced, when this is an upgrade.
    public var replacing: String?
    public var conflicts: [String]
    public var warnings: [String]
    public var errors: [String]

    public init(package: String? = nil, replacing: String? = nil, conflicts: [String] = [], warnings: [String] = [], errors: [String] = []) {
        self.package = package
        self.replacing = replacing
        self.conflicts = conflicts
        self.warnings = warnings
        self.errors = errors
    }

    public var isClean: Bool { errors.isEmpty && conflicts.isEmpty }

    /// A conflict is reported by dpkg as an error as well, and the conflict is
    /// the half that says what to do about it — so it is quoted first.
    public var summary: String {
        if let conflict = conflicts.first { return conflict }
        if let error = errors.first { return error }
        if let replacing { return "Would replace \(replacing)." }
        return "Would install cleanly."
    }
}

public enum InstallPreviewParser {

    public static func parse(_ output: String) -> InstallPreview {
        var preview = InstallPreview()

        for rawLine in output.normalisedLineEndings().split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()

            // A "Preparing to unpack /tmp/….deb" line names a file, not a
            // package, so only the unpacking line is read for the name.
            if lower.hasPrefix("unpacking ") {
                if let parsed = packageName(from: line) {
                    preview.package = parsed
                }
                if preview.replacing == nil, let over = version(after: " over ", in: line) {
                    preview.replacing = over
                }
                continue
            }
            if lower.hasPrefix("preparing to unpack ") { continue }

            // Order matters: a conflict is reported as an error too, and the
            // conflict is the useful half.
            if lower.contains("conflict") || lower.contains("trying to overwrite") {
                preview.conflicts.append(line)
                continue
            }
            if lower.hasPrefix("dpkg: error") || lower.contains("dependency problems") || lower.contains("is not installed") {
                preview.errors.append(line)
                continue
            }
            if lower.contains("warning") {
                preview.warnings.append(line)
            }
        }
        return preview
    }

    /// `Unpacking com.example.a (1.0) over (0.9) ...` → `com.example.a (1.0)`.
    static func packageName(from line: String) -> String? {
        var text = line
        for prefix in ["Preparing to unpack ", "Unpacking "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if let over = text.range(of: " over ") {
            text = String(text[text.startIndex..<over.lowerBound])
        }
        // dpkg ends these lines with " ...", which is not part of the name.
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix(".") {
            trimmed.removeLast()
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The version inside the parentheses after a marker.
    static func version(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let rest = line[range.upperBound...].drop(while: { $0 == "(" })
        guard let close = rest.firstIndex(of: ")") else { return nil }
        let value = String(rest[rest.startIndex..<close])
        return value.isEmpty ? nil : value
    }
}
