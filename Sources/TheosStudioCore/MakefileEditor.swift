import Foundation

/// Editing a Makefile without hand-editing it.
///
/// The one thing that catches every new tweak developer is that a source file
/// that is not in `X_FILES` is never compiled: the file sits in the project, the
/// build succeeds, and the hook does nothing. So adding a file to the project and
/// adding it to the Makefile are the same action here, and this is the code that
/// does the second half without reformatting the first half.
public enum MakefileEditor {

    /// The variable holding the source list: `MyTweak_FILES`, `myapp_FILES`, …
    public static func fileListVariable(in makefile: String) -> String? {
        for name in ["TWEAK_NAME", "APPLICATION_NAME", "TOOL_NAME", "BUNDLE_NAME", "LIBRARY_NAME"] {
            if let value = readValue(name, in: makefile), !value.isEmpty {
                return value + "_FILES"
            }
        }
        return nil
    }

    /// The sources the build actually compiles, in order.
    public static func sources(in makefile: String, variable: String? = nil) -> [String] {
        guard let name = variable ?? fileListVariable(in: makefile),
              let value = readValue(name, in: makefile) else { return [] }
        return value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// Reads `NAME = value`, `NAME :=`, `NAME +=`, joining backslash
    /// continuations — Theos' own templates wrap a long file list over lines.
    public static func readValue(_ name: String, in makefile: String) -> String? {
        let lines = makefile.normalisedLineEndings().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() where assignmentName(in: line) == name {
            guard let start = line.firstIndex(of: "=") else { continue }
            var value = String(line[line.index(after: start)...]).trimmingCharacters(in: .whitespaces)
            var cursor = index
            while value.hasSuffix("\\") {
                value.removeLast()
                cursor += 1
                guard cursor < lines.count else { break }
                value += " " + lines[cursor].trimmingCharacters(in: .whitespaces)
            }
            if let hash = value.range(of: " #") {
                value = String(value[value.startIndex..<hash.lowerBound])
            }
            return value.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The name on the left of an assignment, or nil when the line is not one.
    static func assignmentName(in line: String) -> String? {
        var text = line
        if text.hasPrefix("export ") { text = String(text.dropFirst("export ".count)) }
        guard !text.hasPrefix("#"), !text.hasPrefix("\t") else { return nil }
        for separator in [":=", "+=", "?=", "="] {
            guard let range = text.range(of: separator) else { continue }
            let name = text[text.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            return name
        }
        return nil
    }

    /// Sets a simple value, adding the assignment when it is not there yet.
    public static func setValue(_ name: String, to value: String, in makefile: String) -> String {
        var lines = makefile.normalisedLineEndings().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() where assignmentName(in: line) == name {
            guard let start = line.firstIndex(of: "=") else { continue }
            let operatorText = line[line.startIndex..<start].hasSuffix(":") ? " := " : " = "
            // Keep any trailing comment: it is usually the explanation.
            var comment = ""
            let valueText = String(line[line.index(after: start)...])
            if let hash = valueText.range(of: " #") {
                comment = String(valueText[hash.lowerBound...])
            }
            lines[index] = name + operatorText + value + comment
            return lines.joined(separator: "\n")
        }
        return makefile + "\n" + name + " = " + value + "\n"
    }

    public struct EditResult: Equatable, Sendable {
        public var text: String
        public var changed: Bool
        /// Why nothing changed, for the UI to show rather than leaving the user
        /// wondering whether the file was silently ignored.
        public var reason: String?

        public init(text: String, changed: Bool, reason: String? = nil) {
            self.text = text
            self.changed = changed
            self.reason = reason
        }
    }

    /// Adds a source to the compile list, if it is not already there.
    public static func addSource(_ path: String, to makefile: String) -> EditResult {
        guard let variable = fileListVariable(in: makefile) else {
            return EditResult(
                text: makefile,
                changed: false,
                reason: "The Makefile has no TWEAK_NAME (or APPLICATION_NAME, TOOL_NAME, BUNDLE_NAME), so there is no file list to add to."
            )
        }
        let existing = sources(in: makefile, variable: variable)
        guard !existing.contains(path) else {
            return EditResult(text: makefile, changed: false, reason: "\(path) is already in \(variable).")
        }
        guard let range = assignmentRange(variable, in: makefile) else {
            return EditResult(
                text: makefile,
                changed: false,
                reason: "\(variable) is not in the Makefile; add it by hand (for example: \(variable) = \(path))."
            )
        }

        let line = makefile[range]
        let updated = line + " " + path
        var text = makefile
        text.replaceSubrange(range, with: updated)
        return EditResult(text: text, changed: true)
    }

    public static func removeSource(_ path: String, from makefile: String) -> EditResult {
        guard let variable = fileListVariable(in: makefile),
              let value = readValue(variable, in: makefile) else {
            return EditResult(text: makefile, changed: false, reason: "There is no file list to remove from.")
        }
        var files = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let index = files.firstIndex(of: path) else {
            return EditResult(text: makefile, changed: false, reason: "\(path) is not in \(variable).")
        }
        files.remove(at: index)
        guard let range = assignmentRange(variable, in: makefile) else {
            return EditResult(text: makefile, changed: false, reason: "\(variable) is not in the Makefile.")
        }
        var text = makefile
        let operatorText = makefile[range].contains(":=") ? ":=" : "="
        text.replaceSubrange(range, with: "\(variable) \(operatorText) " + files.joined(separator: " "))
        return EditResult(text: text, changed: true)
    }

    /// The range of the *value* of an assignment, joined across continuations.
    static func assignmentRange(_ name: String, in makefile: String) -> Range<String.Index>? {
        var searchStart = makefile.startIndex
        while let lineRange = makefile.range(of: "\n", range: searchStart..<makefile.endIndex) {
            let lineEnd = lineRange.lowerBound
            let line = String(makefile[searchStart..<lineEnd])
            if assignmentName(in: line) == name, let equals = makefile.range(of: "=", range: searchStart..<lineEnd) {
                var valueStart = equals.upperBound
                while valueStart < lineEnd, makefile[valueStart] == " " || makefile[valueStart] == "\t" {
                    valueStart = makefile.index(after: valueStart)
                }
                var valueEnd = lineEnd
                // Follow the continuations so the whole list is one range.
                //
                // The search starts *after* the newline we are standing on: starting
                // at it finds the same newline again, valueEnd never moves, and the
                // loop runs forever. A wrapped file list — which is what Theos' own
                // templates produce once the list is long enough — is enough to hit
                // it, and a hang in a pure string function is not obvious from the
                // outside.
                while valueEnd > valueStart, makefile[makefile.index(before: valueEnd)] == "\\" {
                    guard valueEnd < makefile.endIndex,
                          let nextLine = makefile.range(of: "\n", range: makefile.index(after: valueEnd)..<makefile.endIndex) else {
                        valueEnd = makefile.endIndex
                        break
                    }
                    valueEnd = nextLine.lowerBound
                }
                return valueStart..<valueEnd
            }
            searchStart = lineRange.upperBound
        }
        // The last line may not end with a newline.
        let line = String(makefile[searchStart...])
        if assignmentName(in: line) == name, let equals = makefile.range(of: "=", range: searchStart..<makefile.endIndex) {
            var valueStart = equals.upperBound
            while valueStart < makefile.endIndex, makefile[valueStart] == " " || makefile[valueStart] == "\t" {
                valueStart = makefile.index(after: valueStart)
            }
            return valueStart..<makefile.endIndex
        }
        return nil
    }

    /// The Theos variable a source file belongs in, and whether that is knowable.
    public static func isSourceFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [".x", ".xm", ".m", ".mm", ".c", ".cc", ".cpp", ".swift"].contains { lower.hasSuffix($0) }
    }
}
