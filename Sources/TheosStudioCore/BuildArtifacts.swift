import Foundation

/// A package a build produced.
public struct BuildArtifact: Equatable, Sendable, Identifiable {
    public var path: String
    public var fileName: String
    public var packageIdentifier: String
    public var version: String
    public var architecture: String
    public var size: Int
    public var date: Date?

    public var id: String { path }

    public var displayVersion: String { "\(version) · \(architecture)" }
}

/// The `.deb` files a project has produced, newest first.
///
/// Keeping them is what makes "it worked ten minutes ago" a question with an
/// answer: the previous package is still there to install, and the version in its
/// name says what changed.
public enum ArtifactHistory {

    /// Parses a Theos package name: `com.example.mytweak_0.0.1_iphoneos-arm64.deb`.
    public static func artifact(path: String, size: Int, date: Date?) -> BuildArtifact? {
        let fileName = (path as NSString).lastPathComponent
        guard let parsed = DebianRepository.parseFileName(fileName) else { return nil }
        return BuildArtifact(
            path: path,
            fileName: fileName,
            packageIdentifier: parsed.packageIdentifier,
            version: parsed.version,
            architecture: parsed.architecture,
            size: size,
            date: date
        )
    }

    /// Newest first, and sorted by the *date* rather than the version: a rebuild
    /// of the same version is the common case, and it is the newer file.
    public static func list(_ candidates: [(path: String, size: Int, date: Date?)]) -> [BuildArtifact] {
        candidates
            .compactMap { artifact(path: $0.path, size: $0.size, date: $0.date) }
            .sorted { lhs, rhs in
                let left = lhs.date ?? .distantPast
                let right = rhs.date ?? .distantPast
                if left != right { return left > right }
                return lhs.fileName > rhs.fileName
            }
    }

    /// The version the newest artifact was built from, which is what a "bump and
    /// rebuild" action needs to move past.
    public static func latestVersion(_ artifacts: [BuildArtifact]) -> String? {
        artifacts.first?.version
    }
}

/// One place a search query appears.
public struct ProjectMatch: Equatable, Sendable, Identifiable {
    public var path: String
    /// 1-based, because that is how the editor and every compiler report them.
    public var line: Int
    public var column: Int
    public var text: String

    public var id: String { "\(path):\(line):\(column)" }

    public init(path: String, line: Int, column: Int, text: String) {
        self.path = path
        self.line = line
        self.column = column
        self.text = text
    }
}

/// Searching every file in a project at once.
///
/// The useful shape for a project this size is different from a code editor's: a
/// tweak is five files, so the answer should say *which file and line*, and the
/// point of the search is usually "where is this class name used".
public enum ProjectSearch {

    public static func matches(
        in files: [ProjectFile],
        query: String,
        caseSensitive: Bool = false,
        limit: Int = 300
    ) -> [ProjectMatch] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }

        var results: [ProjectMatch] = []
        for file in files {
            let lines = file.contents.normalisedLineEndings()
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let haystack = caseSensitive ? String(line) : line.lowercased()
                let target = caseSensitive ? needle : needle.lowercased()
                guard haystack.contains(target) else { continue }

                // Every occurrence on the line, so a line with three uses shows
                // three columns.
                var searchStart = haystack.startIndex
                while let found = haystack.range(of: target, range: searchStart..<haystack.endIndex) {
                    let column = haystack.distance(from: haystack.startIndex, to: found.lowerBound) + 1
                    results.append(ProjectMatch(
                        path: file.path,
                        line: index + 1,
                        column: column,
                        text: line.count > 400 ? String(line.prefix(400)) : String(line)
                    ))
                    searchStart = found.upperBound
                    if results.count >= limit { return results }
                }
            }
        }
        return results
    }

    /// The order a result list wants: the file most likely to matter first, then
    /// by line.
    public static func grouped(_ matches: [ProjectMatch]) -> [(path: String, matches: [ProjectMatch])] {
        var order: [String] = []
        var grouped: [String: [ProjectMatch]] = [:]
        for match in matches {
            if grouped[match.path] == nil { order.append(match.path) }
            grouped[match.path, default: []].append(match)
        }
        return order
            .sorted { lhs, rhs in
                let left = AgentContext.relevance(of: lhs)
                let right = AgentContext.relevance(of: rhs)
                if left != right { return left < right }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .map { path in (path, grouped[path] ?? []) }
    }
}
