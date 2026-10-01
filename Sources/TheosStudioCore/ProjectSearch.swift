import Foundation

public struct ProjectSearchOptions: Equatable, Sendable {
    public var caseSensitive: Bool
    public var useRegex: Bool
    public var wholeWord: Bool
    public var fileExtensions: Set<String>
    public var maximumResults: Int

    public init(caseSensitive: Bool = false, useRegex: Bool = false, wholeWord: Bool = false, fileExtensions: Set<String> = [], maximumResults: Int = 500) {
        self.caseSensitive = caseSensitive
        self.useRegex = useRegex
        self.wholeWord = wholeWord
        self.fileExtensions = Set(fileExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        self.maximumResults = max(1, maximumResults)
    }
}

public struct ProjectSearchResult: Equatable, Sendable, Identifiable {
    public let path: String
    public let line: Int
    public let column: Int
    public let preview: String
    public let matchedText: String

    public init(path: String, line: Int, column: Int, preview: String, matchedText: String) {
        self.path = path
        self.line = line
        self.column = column
        self.preview = preview
        self.matchedText = matchedText
    }

    public var id: String { "\(path):\(line):\(column):\(matchedText)" }
}

public enum ProjectSearch {
    public static func search(query: String, files: [ProjectFile], options: ProjectSearchOptions = .init()) -> [ProjectSearchResult] {
        guard !query.isEmpty else { return [] }

        let pattern: String
        if options.useRegex {
            pattern = options.wholeWord ? "\\b(?:\(query))\\b" : query
        } else {
            let escaped = NSRegularExpression.escapedPattern(for: query)
            pattern = options.wholeWord ? "\\b\(escaped)\\b" : escaped
        }

        let regexOptions: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { return [] }

        var results: [ProjectSearchResult] = []
        for file in files.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            if !options.fileExtensions.isEmpty {
                let ext = (file.path as NSString).pathExtension.lowercased()
                guard options.fileExtensions.contains(ext) else { continue }
            }

            let lines = file.contents.normalisedLineEndings().split(separator: "\n", omittingEmptySubsequences: false)
            for (lineIndex, lineSub) in lines.enumerated() {
                let line = String(lineSub)
                let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
                for match in regex.matches(in: line, options: [], range: nsRange) {
                    guard let range = Range(match.range, in: line) else { continue }
                    let prefix = line[..<range.lowerBound]
                    let column = prefix.count + 1
                    results.append(ProjectSearchResult(
                        path: file.path,
                        line: lineIndex + 1,
                        column: column,
                        preview: line.trimmingCharacters(in: .whitespaces),
                        matchedText: String(line[range])
                    ))
                    if results.count >= options.maximumResults { return results }
                }
            }
        }
        return results
    }
}
