import Foundation

/// One row in the project browser.
public struct ProjectEntry: Equatable, Sendable {
    /// Path relative to the project root, `/`-separated.
    public let relativePath: String
    public let isDirectory: Bool
    public let size: Int

    public init(relativePath: String, isDirectory: Bool, size: Int) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
    }

    public var language: SyntaxLanguage { SyntaxLanguage.forFileName(relativePath) }

    /// Files worth opening in the editor. Everything else is shown too, but the
    /// app will not offer to edit a binary.
    public var isProbablyText: Bool {
        language != .plainText || ["Makefile", "control", "README.md", "README"].contains((relativePath as NSString).lastPathComponent)
    }
}

public enum ProjectFiles {
    /// Build and version-control directories that would bury the five files that
    /// matter in a project of this size.
    public static let hiddenDirectoryNames: Set<String> = [".git", ".theos", ".build", "obj", "DerivedData", ".github"]

    public static func isHidden(_ name: String) -> Bool {
        if hiddenDirectoryNames.contains(name) { return true }
        if name == ".DS_Store" { return true }
        return false
    }

    /// Directories first, then files, each alphabetically — the order a project
    /// browser is read in. `packages/` is pushed to the end because it is output,
    /// not source.
    public static func sort(_ entries: [ProjectEntry]) -> [ProjectEntry] {
        entries.sorted { lhs, rhs in
            let leftIsOutput = lhs.relativePath.hasPrefix("packages/")
            let rightIsOutput = rhs.relativePath.hasPrefix("packages/")
            if leftIsOutput != rightIsOutput { return !leftIsOutput }
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }
}

/// Names and identifiers, kept in one place because they have to agree: the
/// Theos variable, the filter plist, the bundle and the package all take their
/// name from the same string.
public enum ProjectNaming {

    /// `My Tweak!` -> `MyTweak`. Theos uses the name as a C identifier in the
    /// Makefile and as a file name, so anything else has to go.
    public static func sanitize(_ raw: String) -> String {
        var result = ""
        for character in raw {
            if character.isLetter || character.isNumber {
                result.append(character)
            } else if character == " " || character == "_" || character == "-" || character == "." {
                // Word separators are dropped rather than converted: `my-tweak`
                // and `my_tweak` must not both become `mytweak` by accident at
                // this point, the caller decides.
                continue
            }
        }
        if let first = result.first, first.isNumber {
            result = "T" + result
        }
        return result.isEmpty ? "Tweak" : result
    }

    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        guard let first = name.first, first.isLetter, first.isUppercase else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// `MyTweak` -> `com.example.mytweak`. Without an author namespace every
    /// generated project would collide, so one is always included.
    public static func defaultPackageIdentifier(name: String, namespace: String = "example") -> String {
        let slug = name.lowercased().filter { $0.isLetter || $0.isNumber }
        let cleanNamespace = namespace.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." }
        let prefix = cleanNamespace.isEmpty ? "example" : cleanNamespace
        return "com.\(prefix).\(slug.isEmpty ? "tweak" : slug)"
    }

    /// A file name safe for a `.deb` and for a URL.
    public static func safeFileName(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_+~")
        let mapped = raw.map { allowed.contains($0) ? $0 : "-" }
        let text = String(mapped)
        return text.isEmpty ? "package" : text
    }
}
