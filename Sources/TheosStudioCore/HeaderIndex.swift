import Foundation

/// One declaration found in a header.
public struct HeaderDeclaration: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case interface
        case protocolDeclaration = "protocol"
        case property
        case method
        case function

        public var label: String {
            switch self {
            case .interface: return "class"
            case .protocolDeclaration: return "protocol"
            case .property: return "property"
            case .method: return "method"
            case .function: return "function"
            }
        }

        /// Classes and protocols are what you hook; the rest are what you call.
        var rank: Int {
            switch self {
            case .interface: return 0
            case .protocolDeclaration: return 1
            case .method: return 2
            case .property: return 3
            case .function: return 4
            }
        }
    }

    public var kind: Kind
    /// The class name for a class, the selector for a method, the symbol otherwise.
    public var name: String
    /// The class or category the declaration sits in, when it is inside one.
    public var owner: String?
    /// The line as written, for showing the real signature.
    public var signature: String
    public var file: String
    public var line: Int

    public var id: String { "\(file):\(line):\(signature)" }

    /// What to write inside `%hook` for this declaration.
    public var hookable: Bool { kind == .interface || kind == .protocolDeclaration }

    public var location: String {
        "\((file as NSString).lastPathComponent):\(line)"
    }
}

/// Finds the classes and methods that are worth hooking.
///
/// A `%hook` for a class that does not exist on the device is not an error — it
/// silently never fires — so the first job of writing a tweak is confirming that
/// the name is real. The two things on a phone that can answer that are the SDK
/// headers (`$THEOS/sdks`) and whatever header dump the user has, both of which
/// are just text, so this is a text search with an Objective-C reader in front.
public enum HeaderIndex {

    /// Reads declarations out of one header.
    public static func declarations(in text: String, file: String) -> [HeaderDeclaration] {
        var declarations: [HeaderDeclaration] = []
        var owner: String?

        for (index, rawLine) in text.normalisedLineEndings()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lineNumber = index + 1
            guard !line.isEmpty, !line.hasPrefix("//"), !line.hasPrefix("/*"), !line.hasPrefix("*") else { continue }

            if line.hasPrefix("@interface") || line.hasPrefix("@implementation") {
                guard let name = firstIdentifier(after: line.hasPrefix("@implementation") ? "@implementation" : "@interface", in: line) else { continue }
                owner = name
                if line.hasPrefix("@interface") {
                    declarations.append(HeaderDeclaration(
                        kind: .interface, name: name, owner: nil,
                        signature: line, file: file, line: lineNumber
                    ))
                }
                continue
            }

            if line.hasPrefix("@protocol") {
                guard let name = firstIdentifier(after: "@protocol", in: line) else { continue }
                owner = name
                declarations.append(HeaderDeclaration(
                    kind: .protocolDeclaration, name: name, owner: nil,
                    signature: line, file: file, line: lineNumber
                ))
                continue
            }

            if line.hasPrefix("@end") {
                owner = nil
                continue
            }

            if line.hasPrefix("@property") {
                guard let name = propertyName(in: line) else { continue }
                declarations.append(HeaderDeclaration(
                    kind: .property, name: name, owner: owner,
                    signature: line, file: file, line: lineNumber
                ))
                continue
            }

            if line.hasPrefix("- (") || line.hasPrefix("+ (") {
                guard let selector = selector(in: line), !selector.isEmpty else { continue }
                declarations.append(HeaderDeclaration(
                    kind: .method, name: selector, owner: owner,
                    signature: line, file: file, line: lineNumber
                ))
                continue
            }

            if let function = cFunctionName(in: line) {
                declarations.append(HeaderDeclaration(
                    kind: .function, name: function, owner: nil,
                    signature: line, file: file, line: lineNumber
                ))
            }
        }
        return declarations
    }

    /// Ranks matches: an exact name, then a prefix, then a substring, then
    /// anything whose signature contains the query. Classes come before methods
    /// at the same rank, because a class name is what a hook starts with.
    public static func search(_ query: String, in declarations: [HeaderDeclaration], limit: Int = 300) -> [HeaderDeclaration] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        var scored: [(declaration: HeaderDeclaration, score: Int)] = []
        for declaration in declarations {
            let name = declaration.name.lowercased()
            let score: Int
            if name == needle {
                score = 0
            } else if name.hasPrefix(needle) {
                score = 1
            } else if name.contains(needle) {
                score = 2
            } else if declaration.signature.lowercased().contains(needle) {
                score = 3
            } else if let owner = declaration.owner?.lowercased(), owner.contains(needle) {
                // Searching a class name should also return its members.
                score = 4
            } else {
                continue
            }
            scored.append((declaration, score))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                if lhs.declaration.kind.rank != rhs.declaration.kind.rank {
                    return lhs.declaration.kind.rank < rhs.declaration.kind.rank
                }
                return lhs.declaration.name.localizedStandardCompare(rhs.declaration.name) == .orderedAscending
            }
            .prefix(limit)
            .map(\.declaration)
    }

    /// A `%hook` skeleton for a declaration, ready to paste or to write into a
    /// new file — the template that the Theos docs describe, with the class name
    /// already in it.
    public static func hookSkeleton(for declaration: HeaderDeclaration, projectName: String) -> String? {
        guard declaration.hookable else { return nil }
        return """
        // \(declaration.name) — from \(declaration.location)
        //
        // A hook for a class or selector that does not exist on this device does
        // not fail: it silently never fires. Confirm the method names against the
        // device before relying on them.

        %hook \(declaration.name)

        - (void)example {
            %orig;
        }

        %end
        """
    }

    // MARK: - Line readers

    static func firstIdentifier(after keyword: String, in line: String) -> String? {
        let remainder = line.dropFirst(keyword.count)
        let name = remainder
            .drop(while: { $0 == " " || $0 == "\t" })
            .prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
        return name.isEmpty ? nil : String(name)
    }

    /// The last identifier before the `;`: `@property (nonatomic) NSString *name;`
    static func propertyName(in line: String) -> String? {
        var text = line
        // Drop the attribute list, which can contain parentheses and commas.
        if let start = text.firstIndex(of: "("), let end = text.firstIndex(of: ")"), end > start {
            text.removeSubrange(start...end)
        }
        text = text.replacingOccurrences(of: ";", with: "")
        let identifiers = text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
        return identifiers.last.map(String.init)
    }

    /// `- (void)setValue:(id)v forKey:(NSString *)k;` -> `setValue:forKey:`
    static func selector(in line: String) -> String? {
        guard let close = line.firstIndex(of: ")") else { return nil }
        var rest = String(line[line.index(after: close)...])
        if let brace = rest.firstIndex(where: { $0 == ";" || $0 == "{" }) {
            rest = String(rest[rest.startIndex..<brace])
        }

        // Each label is the identifier just before a colon. Colons inside
        // parentheses belong to a parameter type, not to the selector.
        var labels: [String] = []
        var depth = 0
        var current = ""
        for character in rest {
            switch character {
            case "(":
                depth += 1
                current = ""
            case ")":
                depth = max(0, depth - 1)
                current = ""
            case ":" where depth == 0:
                let label = current.trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { labels.append(label + ":") }
                current = ""
            case " ", "\t":
                if !current.isEmpty && depth == 0 { current = "" }
            default:
                if depth == 0 { current.append(character) }
            }
        }

        if labels.isEmpty {
            let name = rest.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return labels.joined()
    }

    /// `static inline int foo(void)` / `void bar(int x);` -> `bar`
    static func cFunctionName(in line: String) -> String? {
        let keywords: Set<String> = ["if", "for", "while", "switch", "return", "sizeof", "typedef", "struct", "enum", "union", "#define", "#import", "#include"]
        if let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first, keywords.contains(String(first)) {
            return nil
        }
        guard let open = line.firstIndex(of: "(") else { return nil }
        let before = String(line[line.startIndex..<open])
        let name = before.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).last.map(String.init)
        guard let name, !name.isEmpty, !keywords.contains(name) else { return nil }
        return name
    }
}
