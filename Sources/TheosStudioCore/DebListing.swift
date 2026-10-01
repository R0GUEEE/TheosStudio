import Foundation

/// One entry inside a built package.
public struct DebEntry: Equatable, Sendable {
    public var path: String
    public var size: Int
    public var isDirectory: Bool

    public init(path: String, size: Int, isDirectory: Bool) {
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
    }

    /// The path as the device sees it, without the listing's leading `./`.
    public var installedPath: String {
        path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }
}

/// One labelled row of a package report.
public struct DebSummaryRow: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Reads `dpkg-deb -c`, so the app can show what a package is about to install
/// *before* it is installed — the check that would have caught a rootful package
/// on a rootless device, or a dylib that landed outside the injector's directory.
public enum DebListing {

    public static func parse(_ output: String) -> [DebEntry] {
        var entries: [DebEntry] = []
        for rawLine in output.normalisedLineEndings().split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 4 else { continue }

            let mode = tokens[0]
            guard let size = Int(tokens[2]) else { continue }

            // The path is whatever begins with "./" — taking it from there means
            // the date and time in between can be in any of the formats the
            // different tar/dpkg builds print.
            guard let pathIndex = tokens.firstIndex(where: { $0.hasPrefix("./") }) else { continue }
            let path = tokens[pathIndex...].joined(separator: " ")
            guard path != "./" else { continue }

            entries.append(DebEntry(
                path: path,
                size: size,
                isDirectory: mode.hasPrefix("d")
            ))
        }
        return entries
    }

    public static func files(_ entries: [DebEntry]) -> [DebEntry] {
        entries.filter { !$0.isDirectory }
    }

    public static func totalSize(_ entries: [DebEntry]) -> Int {
        files(entries).reduce(0) { $0 + $1.size }
    }

    /// The biggest files, which is how a package gets fat by accident — a
    /// forgotten asset, a framework copied whole.
    public static func largest(_ entries: [DebEntry], limit: Int = 5) -> [DebEntry] {
        files(entries).sorted { $0.size > $1.size }.prefix(limit).map { $0 }
    }

    /// True when the package installs where this device would look for it.
    ///
    /// The failure this catches is silent and total: a rootful package on a
    /// rootless device installs a tweak into directories nothing reads.
    public static func matchesScheme(_ entries: [DebEntry], scheme: PackagingScheme) -> Bool {
        let prefixes = files(entries).map(\.installedPath)
        guard !prefixes.isEmpty else { return true }
        switch scheme {
        case .rootless:
            return prefixes.contains { $0.hasPrefix("var/jb/") }
        case .rootful:
            return prefixes.contains { !$0.hasPrefix("var/jb/") }
        case .roothide:
            // roothide resolves its own prefix at runtime; nothing to check.
            return true
        }
    }

    /// A short report for the UI: what the package contains, in the order someone
    /// checking a package wants to see it.
    public static func summary(entries: [DebEntry], control: ControlFile?, scheme: PackagingScheme) -> [DebSummaryRow] {
        var rows: [DebSummaryRow] = []
        let installed = files(entries)
        rows.append(DebSummaryRow(label: "Files", value: "\(installed.count)"))
        rows.append(DebSummaryRow(
            label: "Unpacked size",
            value: ByteCountFormatter.string(fromByteCount: Int64(totalSize(entries)), countStyle: .file)
        ))
        if let identifier = control?.packageIdentifier {
            rows.append(DebSummaryRow(label: "Package", value: identifier))
        }
        if let version = control?.version {
            rows.append(DebSummaryRow(label: "Version", value: version))
        }
        if let architecture = control?.architecture {
            rows.append(DebSummaryRow(label: "Architecture", value: architecture))
        }
        if let depends = control?["Depends"], !depends.isEmpty {
            rows.append(DebSummaryRow(label: "Depends", value: depends))
        }

        let dylibs = installed.filter { $0.installedPath.hasSuffix(".dylib") }
        if !dylibs.isEmpty {
            let names = dylibs.map { ($0.installedPath as NSString).lastPathComponent }
            rows.append(DebSummaryRow(label: "Dylibs", value: names.joined(separator: ", ")))
        }
        let bundles = installed.filter { $0.installedPath.contains(".bundle/") }
        if !bundles.isEmpty {
            let names = Set(bundles.map { ($0.installedPath as NSString).lastPathComponent })
            rows.append(DebSummaryRow(label: "Bundles", value: "\(names.count)"))
        }
        if let deb = installed.first(where: { $0.installedPath.hasSuffix(".deb") }) {
            rows.append(DebSummaryRow(label: "Contains a .deb", value: deb.installedPath))
        }
        if !matchesScheme(entries, scheme: scheme) {
            let ours = scheme == .rootless ? "rootful" : "rootless"
            rows.append(DebSummaryRow(
                label: "Layout",
                value: "This package does not install under \(scheme.installRootDescription) — it is a \(ours) package."
            ))
        }
        return rows
    }
}
