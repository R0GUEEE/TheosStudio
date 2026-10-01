import Foundation
import TheosStudioCore
import SwiftUI

/// Everything the app remembers between launches.
struct StudioSettings: Codable, Equatable {
    var projectsDirectory: String = Paths.defaultProjectsDirectory
    /// Set when Theos is somewhere the search would not look.
    var theosPathOverride: String = ""
    /// `nil` means "use whatever this device looks like".
    var defaultScheme: PackagingScheme?
    var authorName: String = "Your Name"
    var authorEmail: String = "you@example.com"
    var namespace: String = "example"
    /// `FINALPACKAGE=1`: optimised and stripped.
    var finalPackage: Bool = false
    /// Theos does not track header dependencies, so a rebuild-after-edit needs a
    /// clean more often than it should.
    var cleanBeforeBuild: Bool = false
    var verboseBuild: Bool = true
    var jobs: Int = 0
    var editorFontSize: Double = 13
    var respringAfterInstall: Bool = true
    var lastProjectPath: String?

    var effectiveScheme: PackagingScheme {
        defaultScheme ?? .rootless
    }
}

struct Project: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var name: String
    var manifest: ProjectManifest
    /// The most recent `.deb` in `packages/`, if there is one.
    var builtPackage: String?
    var builtDate: Date?

    var kind: ProjectKind? { manifest.kind }
    var scheme: PackagingScheme? { manifest.declaredScheme }
    var packageIdentifier: String? { manifest.packageIdentifier }
    var version: String? { manifest.version }

    var displayScheme: String {
        scheme?.displayName ?? "rootful"
    }
}

struct BannerMessage: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var body: String
}

@MainActor
final class StudioStore: ObservableObject {

    @Published private(set) var projects: [Project] = []
    @Published private(set) var toolchain: ToolchainReport?
    @Published var settings: StudioSettings {
        didSet { persist() }
    }
    @Published var banner: BannerMessage?

    let jailbreak: JailbreakLayout

    private static let settingsKey = "com.r0gueee.theosstudio.settings"

    init() {
        // The settings are read before `jailbreak` is initialised, so the
        // property must be assigned on both paths before `self` is used.
        let stored: StudioSettings
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(StudioSettings.self, from: data) {
            stored = decoded
        } else {
            stored = StudioSettings()
        }
        settings = stored
        jailbreak = JailbreakLayout.detect(exists: { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        })
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    // MARK: - Toolchain

    func refreshToolchain() {
        let override = settings.theosPathOverride.trimmingCharacters(in: .whitespaces)
        toolchain = TheosLocator.report(
            home: NSHomeDirectory(),
            override: override.isEmpty ? nil : override,
            jailbreak: jailbreak,
            base: ProcessInfo.processInfo.environment,
            exists: FS.fileExists,
            listDirectory: FS.list
        )
    }

    var isReadyToBuild: Bool { toolchain?.isReadyToBuild ?? false }

    /// The environment a build runs with: Theos's `PATH` additions plus the
    /// jailbreak's own binary directories.
    func buildEnvironment() -> [String: String] {
        guard let toolchain, let root = toolchain.theosRoot else {
            return ProcessInfo.processInfo.environment
        }
        return TheosLocator.environment(
            theosRoot: root,
            binDirectories: toolchain.binDirectories,
            base: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory()
        )
    }

    // MARK: - Projects

    func reloadProjects() {
        let root = settings.projectsDirectory
        if !FS.directoryExists(root) {
            try? FS.createDirectory(root)
        }
        var found: [Project] = []
        for directory in FS.subdirectories(of: root) {
            guard let project = load(directory: directory) else { continue }
            found.append(project)
        }
        projects = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A directory is a project when it holds the two files Theos needs.
    func load(directory: String) -> Project? {
        let makefile = FS.read(directory + "/Makefile") ?? ""
        let control = FS.read(directory + "/control") ?? ""
        guard !makefile.isEmpty || !control.isEmpty else { return nil }

        let manifest = ProjectManifest.parse(makefile: makefile, control: control)
        let artifact = ArtifactLocator.newestPackage(
            in: directory,
            listDirectory: FS.list,
            modificationDate: FS.modificationDate
        )
        return Project(
            path: directory,
            name: manifest.name ?? (directory as NSString).lastPathComponent,
            manifest: manifest,
            builtPackage: artifact,
            builtDate: artifact.flatMap { FS.modificationDate($0) }
        )
    }

    func project(at path: String) -> Project? {
        projects.first { $0.path == path }
    }

    /// Writes a new project to disk after checking the two things that would make
    /// it unusable: a name Theos cannot use, and an identifier dpkg would reject.
    func createProject(_ request: TemplateRequest) throws -> Project {
        guard ProjectNaming.isValid(request.name) else {
            throw StudioError.invalidName(request.name)
        }
        guard ControlValidator.isValidPackageIdentifier(request.packageIdentifier) else {
            throw StudioError.invalidIdentifier(request.packageIdentifier)
        }

        let directory = settings.projectsDirectory + "/" + request.name
        if FS.directoryExists(directory) {
            throw StudioError.directoryExists(directory)
        }

        try FS.createDirectory(directory)
        for file in ProjectTemplate.files(for: request) {
            try FS.write(file.contents, to: directory + "/" + file.path)
        }

        reloadProjects()
        if let project = load(directory: directory) {
            return project
        }
        throw StudioError.unreadableProject(directory)
    }

    func deleteProject(_ project: Project) throws {
        try FS.remove(project.path)
        reloadProjects()
    }
}

enum StudioError: LocalizedError {
    case invalidName(String)
    case invalidIdentifier(String)
    case directoryExists(String)
    case unreadableProject(String)
    case noToolchain
    case noArtifact

    var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "'\(name)' is not a usable Theos project name. It has to start with a capital letter and contain only letters and digits — Theos uses it as a C identifier and as a file name."
        case .invalidIdentifier(let identifier):
            return "'\(identifier)' is not a valid Debian package identifier. Use lowercase letters, digits and '.', '+' and '-' only."
        case .directoryExists(let path):
            return "There is already something at \(path). Pick another name, or open that project instead."
        case .unreadableProject(let path):
            return "\(path) was written but could not be read back as a project."
        case .noToolchain:
            return "Theos was not found on this device. See the Toolchain tab: it names the missing pieces and the command that installs them."
        case .noArtifact:
            return "No package has been built yet."
        }
    }
}
