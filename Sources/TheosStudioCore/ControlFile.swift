import Foundation

/// One `Key: value` pair of a Debian control file.
public struct ControlField: Equatable, Sendable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// A Debian control file.
///
/// Values survive a round trip exactly, including the newlines a `Description`
/// continuation line is made of, and fields the app does not know about are kept
/// and written back. `serialized()` orders the fields it knows the way Debian
/// conventionally writes them and appends the rest, which makes
/// `parse(serialize(_))` idempotent — the property that matters, because a
/// control file is the one artefact every package manager on the device reads.
public struct ControlFile: Equatable, Sendable {
    public private(set) var fields: [ControlField]

    public init(fields: [ControlField] = []) {
        self.fields = fields
    }

    /// Human-friendly ordering for a *new* file. Existing files keep the order
    /// they were written in, with any recognised field pulled into this order.
    public static let canonicalOrder: [String] = [
        "Package", "Name", "Version", "Architecture", "Section", "Priority",
        "Maintainer", "Author", "Depends", "Pre-Depends", "Recommends", "Suggests",
        "Conflicts", "Replaces", "Provides", "Installed-Size",
        "Homepage", "Depiction", "SileoDepiction", "Icon", "Tag", "Description",
    ]

    public subscript(key: String) -> String? {
        get {
            fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        }
        set {
            if let index = fields.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                if let value = newValue {
                    fields[index].value = value
                } else {
                    fields.remove(at: index)
                }
            } else if let value = newValue {
                fields.append(ControlField(key, value))
            }
        }
    }

    public var packageIdentifier: String? { self["Package"] }
    public var name: String? { self["Name"] }
    public var version: String? { self["Version"] }
    public var architecture: String? { self["Architecture"] }

    // MARK: - Parsing

    /// Parses a control file. Lenient on purpose: a file being edited in the app
    /// is often temporarily malformed and the editor must not lose fields.
    public static func parse(_ source: String) -> ControlFile {
        let text = source.normalisedLineEndings()
        var fields: [ControlField] = []
        var pendingKey: String?
        var pendingValue = ""

        func flush() {
            if let key = pendingKey {
                fields.append(ControlField(key, pendingValue))
            }
            pendingKey = nil
            pendingValue = ""
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard pendingKey != nil else { continue }
                let continuation = line.trimmingCharacters(in: .whitespaces)
                pendingValue += pendingValue.isEmpty ? continuation : "\n" + continuation
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            flush()
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            pendingKey = canonicalKeyCase(key)
            pendingValue = value
        }
        flush()
        return ControlFile(fields: fields)
    }

    /// `Package:` and `package:` mean the same thing; the control file is written
    /// with Debian's capitalisation for the fields we know.
    public static func canonicalKeyCase(_ key: String) -> String {
        let lower = key.lowercased()
        if let known = knownKeyCase[lower] {
            return known
        }
        // Unknown field: capitalise the first letter, leave the rest alone.
        guard let first = key.first else { return key }
        return String(first).uppercased() + String(key.dropFirst())
    }

    private static let knownKeyCase: [String: String] = {
        var map: [String: String] = [:]
        for key in canonicalOrder {
            map[key.lowercased()] = key
        }
        return map
    }()

    // MARK: - Serialising

    public func serialized() -> String {
        var output = ""
        for field in orderedFields() {
            let lines = field.value.split(separator: "\n", omittingEmptySubsequences: false)
            output += "\(field.key): \(lines.first.map(String.init) ?? "")\n"
            for line in lines.dropFirst() {
                output += " \(line)\n"
            }
        }
        return output
    }

    /// Known fields first, in `canonicalOrder`; everything else keeps its
    /// relative position at the end (which is where a hand-added field usually
    /// belongs anyway).
    public func orderedFields() -> [ControlField] {
        var remaining = fields
        var ordered: [ControlField] = []
        for key in Self.canonicalOrder {
            if let index = remaining.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                ordered.append(remaining.remove(at: index))
            }
        }
        ordered.append(contentsOf: remaining)
        return ordered
    }
}

// MARK: - Validation

public struct ValidationIssue: Equatable, Sendable {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public let severity: Severity
    public let message: String

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

/// Checks the fields dpkg actually rejects, plus the two mistakes that produce a
/// package which installs and then does nothing (a missing hooking-library
/// dependency, and a `Name:` that does not match the tweak's filter file).
public enum ControlValidator {
    public static func issues(for control: ControlFile, kind: ProjectKind?, projectName: String?) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        let package = control.packageIdentifier ?? ""
        if package.isEmpty {
            issues.append(.init(.error, "Package: is required — it is the identifier dpkg installs, upgrades and removes by."))
        } else if !isValidPackageIdentifier(package) {
            issues.append(.init(.error, "Package: '\(package)' is not a valid Debian identifier (lowercase letters, digits, '+', '-' and '.' only, and it must start with a letter or digit)."))
        }

        let version = control.version ?? ""
        if version.isEmpty {
            issues.append(.init(.error, "Version: is required — dpkg refuses to install a package without one, and it will not upgrade to an equal version."))
        } else if version.first?.isNumber != true {
            issues.append(.init(.warning, "Version: '\(version)' does not start with a digit; Debian compares versions with a non-numeric epoch first, so this is only allowed when an epoch is present."))
        }

        let architecture = control.architecture ?? ""
        if architecture.isEmpty {
            issues.append(.init(.warning, "Architecture: is empty — Theos fills it in at package time from THEOS_PACKAGE_SCHEME."))
        }

        let maintainer = control["Maintainer"] ?? ""
        if maintainer.isEmpty {
            issues.append(.init(.warning, "Maintainer: is empty; Sileo shows this field on every package page."))
        } else if !maintainer.contains("<") || !maintainer.contains(">") {
            issues.append(.init(.warning, "Maintainer: should be 'Name <email>'; package managers display it verbatim."))
        }

        let description = control["Description"] ?? ""
        if description.isEmpty {
            issues.append(.init(.warning, "Description: is empty; the first line is the only one shown in a package list."))
        } else if description.split(separator: "\n").count > 1 {
            issues.append(.init(.warning, "Only the first line of Description: appears in a package list. Continuation lines need a leading space (the editor writes them for you)."))
        }

        if let kind, kind.needsHookingLibrary {
            let dependencies = (control["Depends"] ?? "") + " " + (control["Pre-Depends"] ?? "") + " " + (control["Recommends"] ?? "")
            let providesHooker = ["mobilesubstrate", "ellekit", "libhooker", "substrate", "orion"].contains { dependencies.lowercased().contains($0) }
            if !providesHooker {
                issues.append(.init(.warning, "A \(kind.displayName.lowercased()) needs a hooking library to load. Add 'mobilesubstrate' (ElleKit provides it) or 'ellekit' to Depends:."))
            }
        }

        if let projectName, let name = control.name, !name.isEmpty, name != projectName {
            issues.append(.init(.warning, "Name: '\(name)' differs from the project name '\(projectName)'. Theos looks for '<TWEAK_NAME>.plist' for the injection filter, so the filter file must be named after the *project*, not after this field."))
        }

        return issues
    }

    public static func isValidPackageIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+-.")
        guard identifier.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard let first = identifier.unicodeScalars.first,
              CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(first) else { return false }
        return !identifier.contains("..")
    }
}
