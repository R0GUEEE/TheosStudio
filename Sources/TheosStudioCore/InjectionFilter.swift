import Foundation

/// The injection filter — the file that decides whether the tweak loads at all.
///
/// It is four lines of old-style plist, and it is the file most likely to be
/// wrong in a way that has consequences: a filter with no entries loads the dylib
/// into every process on the device, which is a bootloop waiting to happen, and a
/// filter naming a bundle identifier that does not exist means the tweak simply
/// never loads, silently.
public struct InjectionFilter: Equatable, Sendable {

    public var bundles: [String]
    public var executables: [String]
    /// The file as it was read, so anything the form does not understand survives
    /// a round trip.
    public var raw: String

    public init(bundles: [String] = [], executables: [String] = [], raw: String = "") {
        self.bundles = bundles
        self.executables = executables
        self.raw = raw
    }

    // MARK: - Parsing

    public static func parse(_ text: String) -> InjectionFilter {
        InjectionFilter(
            bundles: values(named: "Bundles", in: text),
            executables: values(named: "Executables", in: text),
            raw: text
        )
    }

    /// Finds `Name = ( "a", "b" );` and returns the quoted strings inside it.
    static func values(named key: String, in text: String) -> [String] {
        guard let keyRange = text.range(of: key) else { return [] }
        guard let open = text.range(of: "(", range: keyRange.upperBound..<text.endIndex),
              let close = text.range(of: ")", range: open.upperBound..<text.endIndex) else { return [] }

        let list = text[open.upperBound..<close.lowerBound]
        var values: [String] = []
        var remainder = list
        while let first = remainder.firstIndex(of: "\"") {
            let after = remainder[remainder.index(after: first)...]
            guard let last = firstIndex(of: "\"", in: after) else { break }
            values.append(String(after[after.startIndex..<last]))
            remainder = after[after.index(after: last)...]
        }
        return values
    }

    static func firstIndex(of character: Character, in text: Substring) -> Substring.Index? {
        text.firstIndex(of: character)
    }

    // MARK: - Editing

    @discardableResult
    public mutating func add(bundle: String) -> Bool {
        let trimmed = bundle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !bundles.contains(trimmed) else { return false }
        bundles.append(trimmed)
        return true
    }

    @discardableResult
    public mutating func remove(bundle: String) -> Bool {
        guard let index = bundles.firstIndex(of: bundle) else { return false }
        bundles.remove(at: index)
        return true
    }

    @discardableResult
    public mutating func add(executable: String) -> Bool {
        let trimmed = executable.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !executables.contains(trimmed) else { return false }
        executables.append(trimmed)
        return true
    }

    @discardableResult
    public mutating func remove(executable: String) -> Bool {
        guard let index = executables.firstIndex(of: executable) else { return false }
        executables.remove(at: index)
        return true
    }

    // MARK: - Writing

    /// Rewrites only the lists the form edits, leaving the rest of the file — and
    /// its comments — alone.
    public func serialized() -> String {
        var text = raw.isEmpty ? defaultValue : raw

        if !bundles.isEmpty || text.contains("Bundles") {
            text = replaceList(named: "Bundles", with: bundles, in: text)
        }
        if !executables.isEmpty || text.contains("Executables") {
            text = replaceList(named: "Executables", with: executables, in: text)
        }
        // A filter that names nothing is worse than useless; the default is the
        // one process the tweak templates hook.
        if bundles.isEmpty, executables.isEmpty, !text.contains("Filter") {
            text = defaultValue
        }
        return text
    }

    static let defaultValue = """
    {
        Filter = {
            Bundles = ( "com.apple.springboard" );
        };
    }
    """

    static func replaceList(named key: String, with values: [String], in text: String) -> String {
        let list = "( " + values.map { "\"\($0)\"" }.joined(separator: ", ") + " )"

        if let keyRange = text.range(of: key),
           let open = text.range(of: "(", range: keyRange.upperBound..<text.endIndex),
           let close = text.range(of: ")", range: open.upperBound..<text.endIndex) {
            var updated = text
            updated.replaceSubrange(open.lowerBound..<close.upperBound, with: list)
            return updated
        }

        // Not there yet: put it inside the Filter dictionary, which is where the
        // injector looks for it.
        if let filterRange = text.range(of: "{", range: text.range(of: "Filter")?.upperBound ?? text.startIndex..<text.endIndex) {
            var updated = text
            updated.insert(contentsOf: "\n        \(key) = \(list);", at: filterRange.upperBound)
            return updated
        }
        return text
    }

    // MARK: - Consequences

    /// Problems worth telling someone about before they install a tweak that
    /// takes the device down with it.
    public var warnings: [String] {
        var warnings: [String] = []
        if bundles.isEmpty && executables.isEmpty {
            warnings.append("The filter names no process, so the dylib loads into everything on the device. That is how a tweak becomes a bootloop.")
        }
        if !bundles.isEmpty && !executables.isEmpty {
            warnings.append("Bundles and Executables are both set. The injector accepts either; having both is usually a mistake.")
        }
        for bundle in bundles where !bundle.contains(".") {
            warnings.append("“\(bundle)” does not look like a bundle identifier, so nothing will match it and the tweak will never load.")
        }
        if bundles.contains(where: { $0.hasSuffix("*") }) {
            warnings.append("A wildcard in Bundles matches more than you probably intend.")
        }
        return warnings
    }

    public var isPlausible: Bool { warnings.isEmpty }
}
