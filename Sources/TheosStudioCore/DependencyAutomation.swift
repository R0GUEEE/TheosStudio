import Foundation

public struct DependencyInstallPlan: Equatable, Sendable {
    public var missing: [DependencyGroup]
    public var selectedPackages: [String]

    public init(missing: [DependencyGroup], selectedPackages: [String]) {
        self.missing = missing
        self.selectedPackages = selectedPackages
    }

    public var isSatisfied: Bool { missing.isEmpty }

    public func aptArguments(updateFirst: Bool = false) -> [[String]] {
        guard !selectedPackages.isEmpty else { return [] }
        var commands: [[String]] = []
        if updateFirst { commands.append(["apt-get", "update"]) }
        commands.append(["apt-get", "install", "-y"] + selectedPackages)
        return commands
    }

    public var summary: String {
        guard !isSatisfied else { return "All declared package dependencies are satisfied." }
        return "Missing: " + missing.map(\.display).joined(separator: ", ")
            + "\nInstall candidates: " + selectedPackages.joined(separator: " ")
    }
}

public enum DependencyAutomation {
    public static func plan(
        control: String,
        installed: [String: String],
        provides: [String: Set<String>] = [:]
    ) -> DependencyInstallPlan {
        let depends = DependencyCheck.dependencies(inControl: control)
        let missing = DependencyCheck.missing(depends: depends, installed: installed, provides: provides)
        var seen = Set<String>()
        let packages = missing.compactMap { group -> String? in
            guard let name = group.alternatives.first?.name, seen.insert(name).inserted else { return nil }
            return name
        }
        return DependencyInstallPlan(missing: missing, selectedPackages: packages)
    }

    public static func parseInstalled(_ text: String) -> (versions: [String: String], provides: [String: Set<String>]) {
        var versions: [String: String] = [:]
        var providers: [String: Set<String>] = [:]

        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { continue }
            let package = fields[0].split(separator: ":").first.map(String.init) ?? fields[0]
            guard !package.isEmpty else { continue }
            versions[package] = fields[1]

            if fields.count >= 3 {
                for raw in fields[2].split(separator: ",") {
                    let token = raw.trimmingCharacters(in: .whitespaces)
                    let virtual = token.split(separator: " ").first.map(String.init) ?? ""
                    if !virtual.isEmpty { providers[virtual, default: []].insert(package) }
                }
            }
        }
        return (versions, providers)
    }
}
