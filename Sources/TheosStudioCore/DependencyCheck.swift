import Foundation

/// One package a package needs, with whatever version constraint was written.
public struct DependencyAlternative: Equatable, Sendable {
    public var name: String
    /// e.g. `>= 0.9.5000`, exactly as it was written.
    public var constraint: String?

    public init(name: String, constraint: String? = nil) {
        self.name = name
        self.constraint = constraint
    }

    public var display: String {
        constraint.map { "\(name) (\($0))" } ?? name
    }
}

/// A dependency group: any one of these packages satisfies it.
/// `mobilesubstrate | ellekit` is one group with two alternatives.
public struct DependencyGroup: Equatable, Sendable {
    public var alternatives: [DependencyAlternative]

    public init(alternatives: [DependencyAlternative]) {
        self.alternatives = alternatives
    }

    public var display: String {
        alternatives.map(\.display).joined(separator: " | ")
    }
}

/// Checks a package's `Depends:` against what is installed.
///
/// The failure this prevents is quiet in the worst way: a tweak installed without
/// its hooking library sits on the device doing nothing, and the user has no
/// reason to connect the two. dpkg reports missing *pre*dependencies itself, but
/// `Depends:` is a promise, not a barrier, so nothing stops it.
public enum DependencyCheck {

    /// Parses `Depends:` or `Pre-Depends:` text into groups of alternatives.
    public static func parse(_ depends: String) -> [DependencyGroup] {
        depends
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { entry -> DependencyGroup? in
                let alternatives = entry
                    .split(separator: "|")
                    .compactMap { alternative(from: String($0)) }
                return alternatives.isEmpty ? nil : DependencyGroup(alternatives: alternatives)
            }
    }

    /// `mobilesubstrate (>= 0.9.5000) [iphoneos-arm64] <!nocheck>` → name + constraint.
    static func alternative(from text: String) -> DependencyAlternative? {
        var working = text

        // Architecture restrictions and build profiles are about building the
        // package, not about installing it.
        for (open, close) in [("[", "]"), ("<", ">")] {
            while let start = working.firstIndex(of: Character(open)),
                  let end = working[start...].firstIndex(of: Character(close)) {
                working.removeSubrange(start...end)
            }
        }

        var constraint: String?
        if let open = working.firstIndex(of: "("),
           let close = working[open...].firstIndex(of: ")") {
            constraint = String(working[working.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            working.removeSubrange(open...close)
        }

        // A virtual package can be written `name:any` or `name:arch`.
        let name = working
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .first
            .map(String.init) ?? ""

        guard !name.isEmpty else { return nil }
        return DependencyAlternative(name: name, constraint: constraint)
    }

    /// The groups nothing installed satisfies.
    ///
    /// `installed` maps a package name to its version; `provides` maps a virtual
    /// name to the packages that provide it (dpkg-query's `${Provides}`), because
    /// ElleKit satisfies `mobilesubstrate` by providing it.
    public static func missing(
        depends: String,
        installed: [String: String],
        provides: [String: Set<String>] = [:]
    ) -> [DependencyGroup] {
        parse(depends).filter { !satisfies($0, installed: installed, provides: provides) }
    }

    public static func satisfies(
        _ group: DependencyGroup,
        installed: [String: String],
        provides: [String: Set<String>] = [:]
    ) -> Bool {
        group.alternatives.contains { alternative in
            if let version = installed[alternative.name] {
                return satisfies(version, constraint: alternative.constraint)
            }
            // A package that provides the name counts, but its own version says
            // nothing about the version of the name it provides, so a versioned
            // constraint on a virtual package cannot be checked here.
            if let providers = provides[alternative.name], !providers.isEmpty {
                return alternative.constraint == nil || providers.contains { installed[$0] != nil }
            }
            return false
        }
    }

    /// `1.2.3` against `>= 1.0` — using Debian's ordering, not string comparison.
    public static func satisfies(_ version: String, constraint: String?) -> Bool {
        guard let constraint, !constraint.isEmpty else { return true }
        let parts = constraint.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else { return true }
        let (op, wanted) = (parts[0], parts[1])
        let comparison = DebianVersion.compare(version, wanted)

        switch op {
        case ">=", "=>": return comparison >= 0
        case "<=", "=<": return comparison <= 0
        case ">>", ">": return comparison > 0
        case "<<", "<": return comparison < 0
        case "=", "==":
            // Debian's `=` compares the upstream version, ignoring the revision,
            // which is what makes `= 1.0` match `1.0-3`.
            let left = DebianVersion.split(version).upstream
            let right = DebianVersion.split(wanted).upstream
            return DebianVersion.verrevcmp(left, right) == 0
        default: return true
        }
    }

    /// `Depends:` for a package, as dpkg-deb -f prints it.
    public static func dependencies(inControl control: String) -> String {
        let file = ControlFile.parse(control)
        let depends = [file["Pre-Depends"], file["Depends"]].compactMap { $0 }.filter { !$0.isEmpty }
        return depends.joined(separator: ", ")
    }
}
