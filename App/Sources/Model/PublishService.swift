import Foundation
import TheosStudioCore

/// Turning built packages into something you can hand to a package manager.
@MainActor
enum PublishService {

    /// Reads a `.deb` into everything an index needs: its control file, its size
    /// and its hash.
    static func package(debPath: String, relativePath: String, store: StudioStore) async -> RepositoryPackage? {
        guard let controlText = await DpkgService.control(debPath: debPath, store: store)?.output,
              !controlText.isEmpty else { return nil }

        let control = ControlFile.parse(controlText)
        guard let data = FileManager.default.contents(atPath: debPath) else { return nil }

        return RepositoryPackage(
            control: control,
            fileName: (debPath as NSString).lastPathComponent,
            relativePath: relativePath,
            size: data.count,
            sha256: SHA256.hex([UInt8](data))
        )
    }

    /// Every `.deb` a project has built, newest first.
    static func artifacts(project: Project) -> [BuildArtifact] {
        let directory = BuildPlanner.packagesDirectory(for: project.path)
        let listing = FS.list(directory)
            .filter { $0.hasSuffix(".deb") }
            .map { name -> (path: String, size: Int, date: Date?) in
                let path = directory + "/" + name
                return (path, FS.size(path), FS.modificationDate(path))
            }
        return ArtifactHistory.list(listing)
    }

    struct ExportResult {
        var directory: String
        var packages: Int
        var files: [String]
        var warnings: [String]
    }

    enum ExportError: LocalizedError {
        case noPackages
        case write(String)

        var errorDescription: String? {
            switch self {
            case .noPackages:
                return "There are no built packages to publish yet. Build the project first."
            case .write(let path):
                return "Could not write \(path)."
            }
        }
    }

    /// Writes a flat repository: the packages under `debs/`, a `Packages` index,
    /// a `Release` file and a small index.html. This is the whole format — three
    /// files and a folder, which is what makes it publishable from a phone.
    static func export(
        project: Project,
        store: StudioStore,
        directory: String,
        label: String,
        description: String
    ) async throws -> ExportResult {
        let artifacts = artifacts(project: project)
        guard !artifacts.isEmpty else { throw ExportError.noPackages }

        // Kept as pairs: a package that cannot be read is skipped, and the copy
        // below must not then be off by one artifact.
        var entries: [(artifact: BuildArtifact, package: RepositoryPackage)] = []
        var warnings: [String] = []

        for artifact in artifacts {
            guard let package = await package(
                debPath: artifact.path,
                relativePath: "./debs/\(artifact.fileName)",
                store: store
            ) else {
                warnings.append("Could not read \(artifact.fileName) — skipped.")
                continue
            }
            entries.append((artifact, package))
        }
        guard !entries.isEmpty else { throw ExportError.noPackages }
        let packages = entries.map(\.package)

        var written: [String] = []
        do {
            try FS.createDirectory(directory)
            try FS.createDirectory(directory + "/debs")

            for entry in entries {
                let destination = directory + "/debs/" + entry.package.fileName
                if !FS.fileExists(destination) {
                    try FileManager.default.copyItem(atPath: entry.artifact.path, toPath: destination)
                }
                written.append("debs/\(entry.package.fileName)")
            }

            let packagesText = DebianRepository.packagesFile(packages)
            try FS.write(packagesText, to: directory + "/Packages")
            written.append("Packages")

            let architectures = Set(packages.compactMap { $0.control.architecture }).sorted()
            try FS.write(
                DebianRepository.releaseFile(
                    label: label,
                    description: description,
                    architectures: architectures.isEmpty ? ["iphoneos-arm64"] : architectures
                ),
                to: directory + "/Release"
            )
            written.append("Release")

            try FS.write(
                DebianRepository.indexHTML(label: label, description: description, packages: packages),
                to: directory + "/index.html"
            )
            written.append("index.html")
        } catch {
            throw ExportError.write(directory)
        }

        return ExportResult(
            directory: directory,
            packages: packages.count,
            files: written,
            warnings: warnings
        )
    }

    /// The installed-package database, plus what each installed package provides:
    /// `Provides` is why ElleKit can satisfy a dependency on mobilesubstrate.
    static func installedDatabase(store: StudioStore) async -> (versions: [String: String], provides: [String: Set<String>]) {
        guard let tool = store.toolPaths(for: ["dpkg-query"])["dpkg-query"] else { return ([:], [:]) }
        let result = await run(
            executable: tool,
            arguments: ["-W", "-f", "${Package}\t${Version}\t${Provides}\n"],
            store: store
        )
        var versions: [String: String] = [:]
        var provides: [String: Set<String>] = [:]

        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let name = parts.first, !name.isEmpty else { continue }
            versions[name] = parts.count > 1 ? parts[1] : ""
            if parts.count > 2, !parts[2].isEmpty {
                for virtual in parts[2].split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !virtual.isEmpty {
                    // `Provides` may carry a version: `foo (= 1.0)`.
                    let bare = virtual.split(separator: " ").first.map(String.init) ?? virtual
                    provides[bare, default: []].insert(name)
                }
            }
        }
        return (versions, provides)
    }

    /// The dependencies of a package that nothing installed satisfies.
    static func missingDependencies(debPath: String, store: StudioStore) async -> [DependencyGroup] {
        guard let controlText = await DpkgService.control(debPath: debPath, store: store)?.output else { return [] }
        let database = await installedDatabase(store: store)
        return DependencyCheck.missing(
            depends: DependencyCheck.dependencies(inControl: controlText),
            installed: database.versions,
            provides: database.provides
        )
    }

    private static func run(executable: String, arguments: [String], store: StudioStore) async -> CommandResult {
        await withCheckedContinuation { continuation in
            var resumed = false
            let process = ShellProcess(executable: executable, arguments: arguments, environment: store.commandEnvironment())
            var output = ""
            do {
                try process.run(onLine: { line in output += line + "\n" }, onExit: { outcome in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: CommandResult(
                        status: outcome.status,
                        output: output.isEmpty ? outcome.output : output
                    ))
                })
            } catch {
                continuation.resume(returning: CommandResult(status: 127, output: error.localizedDescription))
            }
        }
    }
}
