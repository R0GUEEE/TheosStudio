import Foundation

/// Debian version ordering, which is not string ordering.
///
/// `1.0~beta` sorts *before* `1.0`, `1:1.0` sorts after `2.0`, and `1.10` is
/// newer than `1.9`. Getting this wrong in a repository index means a package
/// that never upgrades; getting it wrong in a dependency check means telling
/// someone a package is missing when it is installed.
public enum DebianVersion {

    /// Negative when `lhs` is older, positive when newer, zero when equal.
    public static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = split(lhs)
        let right = split(rhs)

        if left.epoch != right.epoch {
            return left.epoch < right.epoch ? -1 : 1
        }

        let upstream = verrevcmp(left.upstream, right.upstream)
        if upstream != 0 { return upstream }
        return verrevcmp(left.revision, right.revision)
    }

    public static func isOlder(_ lhs: String, than rhs: String) -> Bool { compare(lhs, rhs) < 0 }

    /// `epoch:upstream-revision`, with the revision optional.
    static func split(_ version: String) -> (epoch: Int, upstream: [Character], revision: [Character]) {
        var text = Array(version)
        var epoch = 0

        if let colon = text.firstIndex(of: ":") {
            let epochText = String(text[text.startIndex..<colon])
            if let parsed = Int(epochText) { epoch = parsed }
            text = Array(text[text.index(after: colon)...])
        }

        var revision: [Character] = []
        if let dash = text.lastIndex(of: "-") {
            revision = Array(text[text.index(after: dash)...])
            text = Array(text[text.startIndex..<dash])
        }

        return (epoch, text, revision)
    }

    /// dpkg's `verrevcmp`: compare the non-digits as text, then the digits as
    /// numbers, and put `~` before everything — including before the end of the
    /// other string, which is what makes `1.0~rc1` older than `1.0`.
    static func verrevcmp(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var i = 0
        var j = 0

        while i < lhs.count || j < rhs.count {
            var firstDifference = 0

            while (i < lhs.count && !lhs[i].isNumber) || (j < rhs.count && !rhs[j].isNumber) {
                let left = i < lhs.count ? order(lhs[i]) : 0
                let right = j < rhs.count ? order(rhs[j]) : 0
                if left != right { return left < right ? -1 : 1 }
                i += 1
                j += 1
            }

            while i < lhs.count && lhs[i] == "0" { i += 1 }
            while j < rhs.count && rhs[j] == "0" { j += 1 }

            while i < lhs.count && j < rhs.count && lhs[i].isNumber && rhs[j].isNumber {
                if firstDifference == 0 {
                    firstDifference = Int(lhs[i].asciiValue ?? 0) - Int(rhs[j].asciiValue ?? 0)
                }
                i += 1
                j += 1
            }

            if i < lhs.count && lhs[i].isNumber { return 1 }
            if j < rhs.count && rhs[j].isNumber { return -1 }
            if firstDifference != 0 { return firstDifference < 0 ? -1 : 1 }
        }
        return 0
    }

    /// Letters sort by their ASCII value, punctuation after them, and `~` before
    /// everything at all.
    static func order(_ character: Character) -> Int {
        if character == "~" { return -1 }
        if character.isNumber { return 0 }
        if character.isLetter { return Int(character.asciiValue ?? 0) }
        return Int(character.asciiValue ?? 0) + 256
    }

    // MARK: - Bumping

    public enum Component: String, CaseIterable, Sendable {
        case major
        case minor
        case patch
        /// The Debian revision — the part after the last dash.
        case revision

        public var displayName: String {
            switch self {
            case .major: return "major"
            case .minor: return "minor"
            case .patch: return "patch"
            case .revision: return "revision"
            }
        }
    }

    /// `0.0.1` → patch `0.0.2`, minor `0.1.0`, major `1.0.0`.
    ///
    /// dpkg will not upgrade a package to a version it considers equal, so a
    /// rebuild with the same `Version:` installs nothing and says nothing.
    public static func bumped(_ version: String, _ component: Component = .patch) -> String {
        let parts = split(version)
        let epochPrefix = parts.epoch > 0 ? "\(parts.epoch):" : ""
        var components = String(parts.upstream).split(separator: ".").map(String.init)

        if component == .revision {
            let revision = String(parts.revision)
            let bumpedRevision = revision.isEmpty ? "1" : bumpLastNumber(in: revision)
            return epochPrefix + String(parts.upstream) + "-" + bumpedRevision
        }

        let index: Int
        switch component {
        case .major: index = 0
        case .minor: index = 1
        case .patch: index = 2
        case .revision: index = 0   // handled above
        }

        while components.count <= index { components.append("0") }
        components[index] = bumpLastNumber(in: components[index])
        // Bumping a more significant component resets the ones after it: 0.9.3
        // going to 1.0 should not read 1.0.3.
        if index < components.count - 1 {
            for position in (index + 1)..<components.count where Int(components[position]) != nil {
                components[position] = "0"
            }
        }

        let upstream = components.joined(separator: ".")
        let revision = parts.revision.isEmpty ? "" : "-" + String(parts.revision)
        return epochPrefix + upstream + revision
    }

    /// Increments the last run of digits, or appends `.1` when there is none.
    static func bumpLastNumber(in text: String) -> String {
        let characters = Array(text)
        var end = characters.count
        while end > 0, !characters[end - 1].isNumber { end -= 1 }
        guard end > 0 else { return text + ".1" }

        var start = end
        while start > 0, characters[start - 1].isNumber { start -= 1 }
        let number = Int(String(characters[start..<end])) ?? 0
        return String(characters[0..<start]) + String(number + 1) + String(characters[end...])
    }
}
