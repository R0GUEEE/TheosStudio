import Foundation

/// Which token rules to apply to a file.
public enum SyntaxLanguage: String, CaseIterable, Sendable {
    /// Objective-C, Objective-C++ and Logos (the `%hook` directives), plus Swift.
    case code
    case makefile
    case controlFile
    case plist
    case plainText

    /// Chooses by file name. Logos sources are `.x`/`.xm` and are ordinary
    /// Objective-C apart from the `%` directives, so they share the `code` rules.
    public static func forFileName(_ name: String) -> SyntaxLanguage {
        let lower = name.lowercased()
        let base = (name as NSString).lastPathComponent
        if base == "Makefile" || lower.hasSuffix(".mk") || lower.hasSuffix("makefile") {
            return .makefile
        }
        if base == "control" {
            return .controlFile
        }
        if lower.hasSuffix(".plist") {
            return .plist
        }
        for suffix in [".x", ".xm", ".m", ".mm", ".h", ".hh", ".hpp", ".c", ".cc", ".cpp", ".swift"] where lower.hasSuffix(suffix) {
            return .code
        }
        return .plainText
    }
}

/// A coloured run of the text. Offsets are UTF-16, i.e. exactly what
/// `NSAttributedString` and `UITextView` address text with.
public struct SyntaxToken: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case keyword
        case type
        case string
        case comment
        case number
        case preprocessor
        /// Logos directives: `%hook`, `%orig`, `%ctor`, …
        case directive
        case variable
        case field
    }

    public let location: Int
    public let length: Int
    public let kind: Kind

    public init(location: Int, length: Int, kind: Kind) {
        self.location = location
        self.length = length
        self.kind = kind
    }

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// A small scanner, not a parser: it only has to colour text correctly enough to
/// read, and never to interpret it.
public enum SyntaxHighlighter {

    public static func tokens(in text: String, language: SyntaxLanguage) -> [SyntaxToken] {
        guard !text.isEmpty, language != .plainText else { return [] }
        let units = Array(text.utf16)
        switch language {
        case .code:
            return codeTokens(units)
        case .makefile:
            return makefileTokens(units)
        case .controlFile:
            return controlTokens(units)
        case .plist:
            return plistTokens(units)
        case .plainText:
            return []
        }
    }

    // MARK: - Character helpers

    private static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
    }

    private static func isIdentifierBody(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || (unit >= 48 && unit <= 57)
    }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

    private static func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 }

    private static func string(from units: [UInt16], range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    private static func append(_ tokens: inout [SyntaxToken], _ start: Int, _ end: Int, _ kind: SyntaxToken.Kind) {
        guard end > start else { return }
        tokens.append(SyntaxToken(location: start, length: end - start, kind: kind))
    }

    // MARK: - Code

    static let codeKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break",
        "continue", "return", "goto", "sizeof", "typedef", "struct", "enum", "union",
        "static", "extern", "const", "volatile", "inline", "register", "auto",
        "signed", "unsigned", "public", "private", "protected", "class", "template",
        "namespace", "new", "delete", "this", "true", "false", "nullptr", "using",
        "func", "let", "var", "guard", "defer", "extension", "protocol", "init",
        "import", "where", "in", "throws", "rethrows", "inout", "nil", "self",
        "super", "try", "catch", "as", "is", "lazy", "weak", "unowned", "final",
        "override", "mutating", "convenience", "required", "static",
    ]

    static let codeTypes: Set<String> = [
        "void", "int", "char", "short", "long", "float", "double", "bool", "BOOL",
        "id", "instancetype", "SEL", "IMP", "Class", "size_t", "ssize_t", "uint8_t",
        "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t",
        "NSInteger", "NSUInteger", "CGFloat", "String", "Int", "Double", "Bool",
        "Void", "Any", "AnyObject", "Error", "NSString", "NSArray", "NSDictionary",
        "NSObject", "NSError", "UIView", "UIViewController", "UIColor", "UIImage",
        "CGRect", "CGPoint", "CGSize", "CFStringRef", "CFTypeRef",
    ]

    /// Prefixes that name an Apple type: `NSObject`, `SBIconView`, `CGContextRef`.
    static let typePrefixes: Set<String> = [
        "NS", "UI", "CG", "CF", "CA", "CI", "CL", "CM", "SB", "MK", "AV", "WK",
        "PK", "PH", "MP", "MT", "SC", "SK", "QL", "WK", "AR", "ML", "VN", "HK",
        "CN", "EK", "GK", "GL", "MD", "NC", "NW", "SF", "SN", "SP", "TW", "HB",
        "PS", "CT", "CV", "CB", "AD", "AS", "AT", "BN", "BK", "CP", "CS", "DK",
    ]

    static let logosDirectives: Set<String> = [
        "hook", "end", "orig", "ctor", "dtor", "group", "init", "new", "property",
        "subclass", "hookf", "log", "c", "config", "class", "interface", "end",
    ]

    static func codeTokens(_ units: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var index = 0
        let count = units.count

        while index < count {
            let unit = units[index]

            // Line comment.
            if unit == 47, index + 1 < count, units[index + 1] == 47 {
                var end = index + 2
                while end < count, units[end] != 10 { end += 1 }
                append(&tokens, index, end, .comment)
                index = end
                continue
            }

            // Block comment.
            if unit == 47, index + 1 < count, units[index + 1] == 42 {
                var end = index + 2
                while end + 1 < count, !(units[end] == 42 && units[end + 1] == 47) { end += 1 }
                end = min(end + 2, count)
                append(&tokens, index, end, .comment)
                index = end
                continue
            }

            // String literal, including `@"..."`.
            if unit == 34 {
                let start = index
                var end = index + 1
                while end < count {
                    if units[end] == 92 { end += 2; continue }
                    if units[end] == 34 { end += 1; break }
                    if units[end] == 10 { break }
                    end += 1
                }
                append(&tokens, start, min(end, count), .string)
                index = min(end, count)
                continue
            }

            // Character literal.
            if unit == 39, index + 2 < count {
                var end = index + 1
                while end < count, units[end] != 39, units[end] != 10 { end += 1 }
                if end < count, units[end] == 39 { end += 1 }
                append(&tokens, index, end, .string)
                index = end
                continue
            }

            // Preprocessor directive: `#import`, `#define`, … to end of line.
            if unit == 35, isDirectiveStart(units, at: index) {
                var end = index
                while end < count, units[end] != 10 { end += 1 }
                append(&tokens, index, end, .preprocessor)
                index = end
                continue
            }

            // Logos directive: `%hook`, `%orig`, `%ctor`, …
            if unit == 37, index + 1 < count, isIdentifierStart(units[index + 1]) {
                var end = index + 1
                while end < count, isIdentifierBody(units[end]) { end += 1 }
                let word = string(from: units, range: (index + 1)..<end)
                if logosDirectives.contains(word) {
                    append(&tokens, index, end, .directive)
                    index = end
                    continue
                }
            }

            // Number.
            if isDigit(unit) {
                var end = index
                while end < count, isDigit(units[end]) || (units[end] >= 97 && units[end] <= 102)
                    || (units[end] >= 65 && units[end] <= 70) || units[end] == 120 || units[end] == 88
                    || units[end] == 46 || units[end] == 95 {
                    // Stop at a `.` that is not followed by a digit (member access).
                    if units[end] == 46, end + 1 >= count || !isDigit(units[end + 1]) { break }
                    end += 1
                }
                append(&tokens, index, end, .number)
                index = end
                continue
            }

            // Identifier.
            if isIdentifierStart(unit) {
                var end = index
                while end < count, isIdentifierBody(units[end]) { end += 1 }
                let word = string(from: units, range: index..<end)
                if word.hasPrefix("@") {
                    append(&tokens, index, end, .keyword)
                } else if codeKeywords.contains(word) {
                    append(&tokens, index, end, .keyword)
                } else if codeTypes.contains(word) {
                    append(&tokens, index, end, .type)
                } else if let prefix = typePrefixes.first(where: { word.hasPrefix($0) }),
                          word.count > prefix.count,
                          let next = word.dropFirst(prefix.count).first,
                          next.isUppercase {
                    append(&tokens, index, end, .type)
                }
                index = end
                continue
            }

            // `@interface`, `@implementation`: the keyword is the whole word.
            if unit == 64, index + 1 < count, isIdentifierStart(units[index + 1]) {
                var end = index + 1
                while end < count, isIdentifierBody(units[end]) { end += 1 }
                append(&tokens, index, end, .keyword)
                index = end
                continue
            }

            index += 1
        }
        return tokens
    }

    /// `#` counts as a directive only at the start of a line (ignoring spaces) or
    /// right after another directive — otherwise it is an operator.
    private static func isDirectiveStart(_ units: [UInt16], at index: Int) -> Bool {
        var cursor = index - 1
        while cursor >= 0, isSpace(units[cursor]) { cursor -= 1 }
        return cursor < 0 || units[cursor] == 10
    }

    // MARK: - Makefile

    static let makeKeywords: Set<String> = [
        "include", "-include", "export", "unexport", "override", "define", "endef",
        "ifdef", "ifndef", "ifeq", "ifneq", "else", "endif", "vpath",
    ]

    static func makefileTokens(_ units: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var index = 0
        let count = units.count
        var atLineStart = true

        while index < count {
            let unit = units[index]

            if unit == 10 {
                atLineStart = true
                index += 1
                continue
            }
            if atLineStart, isSpace(unit) {
                index += 1
                continue
            }

            // Comment. `\#` is an escaped hash and is not handled: it does not
            // appear in the Makefiles Theos ships.
            if unit == 35 {
                var end = index
                while end < count, units[end] != 10 { end += 1 }
                append(&tokens, index, end, .comment)
                index = end
                continue
            }

            // `$(VAR)` and `${VAR}` references, anywhere on the line.
            if unit == 36, index + 1 < count, units[index + 1] == 40 || units[index + 1] == 123 {
                let closer: UInt16 = units[index + 1] == 40 ? 41 : 125
                var end = index + 2
                while end < count, units[end] != closer, units[end] != 10 { end += 1 }
                if end < count, units[end] == closer { end += 1 }
                append(&tokens, index, end, .variable)
                index = end
                continue
            }

            if atLineStart {
                var end = index
                while end < count, !isSpace(units[end]), units[end] != 10, units[end] != 58, units[end] != 61, units[end] != 43, units[end] != 63 {
                    end += 1
                }
                let word = string(from: units, range: index..<end)
                if makeKeywords.contains(word) {
                    append(&tokens, index, end, .keyword)
                    index = end
                    atLineStart = false
                    continue
                }
                // `NAME = value`, `NAME := value`, `NAME += value`.
                var lookahead = end
                while lookahead < count, isSpace(units[lookahead]) { lookahead += 1 }
                let isAssignment = lookahead < count && (units[lookahead] == 61
                    || ((units[lookahead] == 58 || units[lookahead] == 43 || units[lookahead] == 63)
                        && lookahead + 1 < count && units[lookahead + 1] == 61))
                if isAssignment {
                    append(&tokens, index, end, .variable)
                    index = end
                    atLineStart = false
                    continue
                }
                // `target:` at the start of a line.
                if end < count, units[end] == 58, !(end + 1 < count && units[end + 1] == 61) {
                    append(&tokens, index, end, .keyword)
                    index = end
                    atLineStart = false
                    continue
                }
                index = end
                atLineStart = false
                continue
            }

            index += 1
        }
        return tokens
    }

    // MARK: - Control file

    static func controlTokens(_ units: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var index = 0
        let count = units.count
        var atLineStart = true

        while index < count {
            let unit = units[index]
            if unit == 10 {
                atLineStart = true
                index += 1
                continue
            }
            if atLineStart, unit == 35 {
                var end = index
                while end < count, units[end] != 10 { end += 1 }
                append(&tokens, index, end, .comment)
                index = end
                continue
            }
            if atLineStart, !isSpace(unit), isIdentifierStart(unit) {
                var end = index
                while end < count, isIdentifierBody(units[end]) || units[end] == 45 { end += 1 }
                if end < count, units[end] == 58 {
                    append(&tokens, index, end, .field)
                }
                index = end
                atLineStart = false
                continue
            }
            if unit != 10 { atLineStart = false }
            index += 1
        }
        return tokens
    }

    // MARK: - Property list

    static func plistTokens(_ units: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var index = 0
        let count = units.count

        while index < count {
            let unit = units[index]

            // XML comment.
            if unit == 60, index + 3 < count, units[index + 1] == 33, units[index + 2] == 45, units[index + 3] == 45 {
                var end = index + 4
                while end + 2 < count, !(units[end] == 45 && units[end + 1] == 45 && units[end + 2] == 62) { end += 1 }
                end = min(end + 3, count)
                append(&tokens, index, end, .comment)
                index = end
                continue
            }

            if unit == 34 {
                let start = index
                var end = index + 1
                while end < count, units[end] != 34, units[end] != 10 { end += 1 }
                if end < count, units[end] == 34 { end += 1 }
                append(&tokens, start, min(end, count), .string)
                index = min(end, count)
                continue
            }

            // `<key>` / `</key>`: the tag itself gets the colour, the text
            // between tags stays plain.
            if unit == 60 {
                var end = index + 1
                while end < count, units[end] != 62, units[end] != 10 { end += 1 }
                if end < count, units[end] == 62 { end += 1 }
                append(&tokens, index, end, .keyword)
                index = end
                continue
            }

            index += 1
        }
        return tokens
    }
}
