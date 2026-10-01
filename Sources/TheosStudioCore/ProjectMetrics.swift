import Foundation

public struct ProjectMetrics: Equatable, Sendable {
    public var fileCount: Int
    public var textFileCount: Int
    public var lineCount: Int
    public var nonBlankLineCount: Int
    public var bytes: Int
    public var languages: [String: Int]

    public init(fileCount: Int, textFileCount: Int, lineCount: Int, nonBlankLineCount: Int, bytes: Int, languages: [String: Int]) {
        self.fileCount = fileCount
        self.textFileCount = textFileCount
        self.lineCount = lineCount
        self.nonBlankLineCount = nonBlankLineCount
        self.bytes = bytes
        self.languages = languages
    }

    public static func calculate(files: [ProjectFile]) -> ProjectMetrics {
        var lines = 0, nonBlank = 0, bytes = 0, textFiles = 0
        var languages: [String: Int] = [:]

        for file in files {
            bytes += file.contents.utf8.count
            textFiles += 1
            let split = file.contents.normalisedLineEndings().split(separator: "\n", omittingEmptySubsequences: false)
            lines += split.count
            nonBlank += split.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            let language = SyntaxLanguage.forFileName(file.path)
            let key = String(describing: language)
            languages[key, default: 0] += 1
        }

        return ProjectMetrics(fileCount: files.count, textFileCount: textFiles, lineCount: lines, nonBlankLineCount: nonBlank, bytes: bytes, languages: languages)
    }
}

public enum VersionBumper {
    public enum Part: String, CaseIterable, Sendable { case major, minor, patch, build }

    public static func bump(_ version: String, part: Part) -> String {
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var numbers = pieces.map { Int($0) ?? 0 }
        while numbers.count < 3 { numbers.append(0) }

        switch part {
        case .major:
            numbers[0] += 1; numbers[1] = 0; numbers[2] = 0
        case .minor:
            numbers[1] += 1; numbers[2] = 0
        case .patch:
            numbers[2] += 1
        case .build:
            if numbers.count < 4 { numbers.append(0) }
            numbers[3] += 1
        }
        return numbers.map(String.init).joined(separator: ".")
    }

    public static func updatingControl(_ source: String, part: Part) -> String {
        var control = ControlFile.parse(source)
        let current = control.version?.isEmpty == false ? control.version! : "0.0.0"
        control["Version"] = bump(current, part: part)
        return control.serialized()
    }
}
