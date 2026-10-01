import Foundation

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case context
        case added
        case removed
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    public var prefix: String {
        switch kind {
        case .context: return " "
        case .added: return "+"
        case .removed: return "-"
        }
    }
}

public struct DiffHunk: Equatable, Sendable {
    public var oldStart: Int
    public var newStart: Int
    public var lines: [DiffLine]

    public init(oldStart: Int, newStart: Int, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.newStart = newStart
        self.lines = lines
    }

    public var header: String {
        let oldCount = lines.filter { $0.kind != .added }.count
        let newCount = lines.filter { $0.kind != .removed }.count
        return "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }
}

/// A line diff, for one purpose: showing the user what the assistant is about to
/// change before it changes it. It is deliberately conservative — when the two
/// versions are too different to align cheaply it says so with a coarse diff
/// rather than spending a phone's CPU on an optimal one.
public enum UnifiedDiff {

    /// Lines beyond this are not diffed pairwise; the edit is reported as a
    /// replacement. A tweak file that large has a different problem.
    public static let pairwiseLimit = 1500

    public static func lines(from old: String, to new: String) -> [DiffLine] {
        let oldLines = old.normalisedLineEndings().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.normalisedLineEndings().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if oldLines == newLines { return oldLines.map { DiffLine(kind: .context, text: $0) } }

        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        let oldMiddle = Array(oldLines[prefix..<(oldLines.count - suffix)])
        let newMiddle = Array(newLines[prefix..<(newLines.count - suffix)])

        var result: [DiffLine] = oldLines[0..<prefix].map { DiffLine(kind: .context, text: $0) }

        if oldMiddle.count > pairwiseLimit || newMiddle.count > pairwiseLimit {
            result += oldMiddle.map { DiffLine(kind: .removed, text: $0) }
            result += newMiddle.map { DiffLine(kind: .added, text: $0) }
        } else {
            result += align(old: oldMiddle, new: newMiddle)
        }

        if suffix > 0 {
            result += oldLines[(oldLines.count - suffix)...].map { DiffLine(kind: .context, text: $0) }
        }
        return result
    }

    /// Longest common subsequence over the changed region, emitting removals
    /// before additions so a replacement reads the way a patch does.
    static func align(old: [String], new: [String]) -> [DiffLine] {
        guard !old.isEmpty || !new.isEmpty else { return [] }
        if old.isEmpty { return new.map { DiffLine(kind: .added, text: $0) } }
        if new.isEmpty { return old.map { DiffLine(kind: .removed, text: $0) } }

        var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var result: [DiffLine] = []
        var i = 0
        var j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                result.append(DiffLine(kind: .context, text: old[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                result.append(DiffLine(kind: .removed, text: old[i]))
                i += 1
            } else {
                result.append(DiffLine(kind: .added, text: new[j]))
                j += 1
            }
        }
        while i < old.count {
            result.append(DiffLine(kind: .removed, text: old[i]))
            i += 1
        }
        while j < new.count {
            result.append(DiffLine(kind: .added, text: new[j]))
            j += 1
        }
        return result
    }

    /// Groups changed lines with `context` lines around them.
    public static func hunks(from old: String, to new: String, context: Int = 3) -> [DiffHunk] {
        let lines = lines(from: old, to: new)
        var hunks: [DiffHunk] = []
        var index = 0
        var oldLine = 1
        var newLine = 1

        while index < lines.count {
            guard lines[index].kind != .context else {
                index += 1
                oldLine += 1
                newLine += 1
                continue
            }

            // Rewind for the leading context. The counters go back with it; the
            // hunk's numbers are computed from where the hunk *starts*, not from
            // where the scan happened to be, or a second hunk would be numbered
            // from the end of the first.
            var hunkStart = index
            var hunkOld = oldLine
            var hunkNew = newLine
            var rewound = 0
            while rewound < context, hunkStart > 0, lines[hunkStart - 1].kind == .context {
                hunkStart -= 1
                hunkOld -= 1
                hunkNew -= 1
                rewound += 1
            }

            var body: [DiffLine] = []
            var cursor = hunkStart
            var quietRun = 0
            while cursor < lines.count {
                let line = lines[cursor]
                if line.kind == .context {
                    quietRun += 1
                    // Stop once the quiet stretch is longer than twice the
                    // context: the tail belongs to the next hunk.
                    if quietRun > context * 2 { break }
                } else {
                    quietRun = 0
                }
                body.append(line)
                cursor += 1
            }

            // At most `context` trailing context lines.
            var trailing = 0
            for line in body.reversed() {
                if line.kind == .context { trailing += 1 } else { break }
            }
            if trailing > context {
                body.removeLast(trailing - context)
            }

            hunks.append(DiffHunk(oldStart: hunkOld, newStart: hunkNew, lines: body))

            // Count every line the hunk *covered*, not just the ones it printed:
            // the context the body dropped between two changes still exists in
            // both files, and forgetting it puts every later hunk at the wrong
            // line number.
            var oldCursor = hunkOld
            var newCursor = hunkNew
            for line in lines[hunkStart..<cursor] {
                switch line.kind {
                case .context:
                    oldCursor += 1
                    newCursor += 1
                case .removed:
                    oldCursor += 1
                case .added:
                    newCursor += 1
                }
            }
            oldLine = oldCursor
            newLine = newCursor
            index = cursor
        }
        return hunks
    }

    public static func stats(from old: String, to new: String) -> (added: Int, removed: Int) {
        let lines = lines(from: old, to: new)
        return (
            lines.filter { $0.kind == .added }.count,
            lines.filter { $0.kind == .removed }.count
        )
    }

    /// A patch, as text. Used in the approval sheet and when copying a change out
    /// of the app.
    public static func render(from old: String, to new: String, path: String) -> String {
        let hunks = hunks(from: old, to: new)
        guard !hunks.isEmpty else { return "\(path): no changes" }
        var output = "--- a/\(path)\n+++ b/\(path)\n"
        for hunk in hunks {
            output += hunk.header + "\n"
            for line in hunk.lines {
                output += line.prefix + line.text + "\n"
            }
        }
        return output
    }
}
