import Foundation

/// One `.deb` as a repository index describes it.
public struct RepositoryPackage: Equatable, Sendable {
    /// Every control field, in the order they will be written.
    public var control: ControlFile
    /// The file name as it appears in the repo, e.g. `com.example.mytweak_1.0_iphoneos-arm64.deb`.
    public var fileName: String
    /// Where the file sits relative to the repo root, e.g. `./debs/…`.
    public var relativePath: String
    public var size: Int
    public var sha256: String

    public init(control: ControlFile, fileName: String, relativePath: String, size: Int, sha256: String) {
        self.control = control
        self.fileName = fileName
        self.relativePath = relativePath
        self.size = size
        self.sha256 = sha256
    }
}

/// Builds a flat Debian repository — the kind Sileo, Zebra and Cydia read.
///
/// Three files and a folder of packages is the whole format. What is easy to get
/// wrong is the part nobody sees until it fails: `Size:` and `SHA256:` have to be
/// the real ones, or the package downloads and then refuses to install with a
/// message about a corrupt archive.
public enum DebianRepository {

    /// The `Packages` index: one stanza per package, in the order given.
    public static func packagesFile(_ packages: [RepositoryPackage]) -> String {
        packages.map(stanza).joined(separator: "\n")
    }

    public static func stanza(_ package: RepositoryPackage) -> String {
        var control = package.control
        // The index needs the file name relative to the repo root; the package's
        // own control file must not carry these fields, so they are added to a
        // copy rather than to the file on disk.
        control["Filename"] = package.relativePath
        control["Size"] = String(package.size)
        control["SHA256"] = package.sha256
        if control["Priority"] == nil { control["Priority"] = "optional" }

        // Description continuation lines are written by ControlFile.serialized()
        // with the leading space Debian wants.
        return control.serialized().trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// The `Release` file: who the repo is and what is in it.
    public static func releaseFile(
        origin: String = "TheosStudio",
        label: String,
        description: String,
        architectures: [String],
        components: [String] = ["main"],
        version: String = "1.0",
        codename: String = "ios"
    ) -> String {
        var lines: [String] = []
        lines.append("Origin: \(origin)")
        lines.append("Label: \(label)")
        lines.append("Suite: stable")
        lines.append("Version: \(version)")
        lines.append("Codename: \(codename)")
        lines.append("Architectures: \(architectures.isEmpty ? "iphoneos-arm64" : architectures.joined(separator: " "))")
        lines.append("Components: \(components.joined(separator: " "))")
        lines.append("Description: \(description)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A minimal `index.html`, so a repo pushed to GitHub Pages says what it is
    /// instead of showing a directory listing.
    public static func indexHTML(label: String, description: String, packages: [RepositoryPackage]) -> String {
        let rows = packages.map { package -> String in
            let name = package.control.name ?? package.control.packageIdentifier ?? package.fileName
            let version = package.control.version ?? "?"
            return "    <li><strong>\(escape(name))</strong> \(escape(version)) — <code>\(escape(package.fileName))</code></li>"
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(label))</title>
        <style>
        body { font: 15px -apple-system, system-ui, sans-serif; margin: 2rem auto; max-width: 42rem; padding: 0 1rem; line-height: 1.5; }
        code { background: rgba(127,127,127,.15); padding: .1em .3em; border-radius: 4px; }
        </style>
        </head>
        <body>
        <h1>\(escape(label))</h1>
        <p>\(escape(description))</p>
        <p>Add this URL in Sileo or Zebra:</p>
        <pre><code>\(escape(label))</code></pre>
        <ul>
        \(rows)
        </ul>
        </body>
        </html>
        """
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `com.example.mytweak_1.0.0_iphoneos-arm64.deb` — the Debians' own naming,
    /// which is worth keeping because every package tool parses it.
    public static func fileName(packageIdentifier: String, version: String, architecture: String) -> String {
        "\(packageIdentifier)_\(version)_\(architecture).deb"
    }

    public static func parseFileName(_ name: String) -> (packageIdentifier: String, version: String, architecture: String)? {
        guard name.hasSuffix(".deb") else { return nil }
        let stem = String(name.dropLast(4))
        let parts = stem.split(separator: "_").map(String.init)
        guard parts.count >= 3 else { return nil }
        let version = parts[parts.count - 2]
        let architecture = parts[parts.count - 1]
        let identifier = parts.dropLast(2).joined(separator: "_")
        guard !identifier.isEmpty else { return nil }
        return (identifier, version, architecture)
    }
}
