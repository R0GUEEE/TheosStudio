import Foundation

/// An SDK release asset from `theos/sdks`, e.g. `iPhoneOS16.5.sdk`.
public struct SDKAsset: Equatable, Sendable {
    public var name: String
    public var url: String
    public var version: String

    public init(name: String, url: String, version: String) {
        self.name = name
        self.url = url
        self.version = version
    }
}

/// What a step does.
public enum InstallStepKind: Equatable, Sendable {
    /// Run a tool that is already on the device.
    case command(tool: String, arguments: [String])
    /// Fetch a file. Done by the app itself rather than by `curl`, because a
    /// device without curl can still download an SDK, and because the app can
    /// report progress on it.
    case download(url: String, to: String)
}

/// One step in an installation.
public struct InstallStep: Equatable, Sendable {
    public var label: String
    public var kind: InstallStepKind
    public var requiresRoot: Bool
    /// When this path exists the step is already done.
    public var skipIfExists: String?
    /// A step that may fail without failing the installation: the next step is
    /// its fallback. This is how "unpack with tar, and if this tar has no xz
    /// support, decompress first" is expressed as a plan.
    public var tolerateFailure: Bool
    public var note: String?

    public init(
        label: String,
        kind: InstallStepKind,
        requiresRoot: Bool = false,
        skipIfExists: String? = nil,
        tolerateFailure: Bool = false,
        note: String? = nil
    ) {
        self.label = label
        self.kind = kind
        self.requiresRoot = requiresRoot
        self.skipIfExists = skipIfExists
        self.tolerateFailure = tolerateFailure
        self.note = note
    }

    /// The tool this step runs, for the app to resolve to a path. `nil` for a
    /// download, which needs no tool at all.
    public var tool: String? {
        if case .command(let tool, _) = kind { return tool }
        return nil
    }

    public var arguments: [String] {
        if case .command(_, let arguments) = kind { return arguments }
        return []
    }
}

/// What an installation is for.
///
/// Separate entry points because the three parts fail for different reasons and
/// need different privileges: the packages need root, cloning Theos needs a
/// writable folder, and an SDK needs neither.
public enum InstallScope: String, CaseIterable, Sendable {
    /// Clone Theos if it is not there, and fetch an SDK.
    case theosAndSDK
    /// Only fetch an SDK into an existing Theos. Nothing else runs, so a broken
    /// checkout cannot stop it.
    case sdkOnly
    /// Only install the dependency packages. Needs root.
    case dependenciesOnly
}

public struct TheosInstallOptions: Equatable, Sendable {
    /// Where Theos goes. A path the app can write: installing Theos into the
    /// bootstrap needs root, and Theos explicitly refuses to be installed or run
    /// as root, so a directory in the app's own document folder is the right
    /// answer, not a compromise.
    public var destination: String
    public var scope: InstallScope
    /// Resolved from the GitHub API by the caller; the plan only places it.
    public var sdkAsset: SDKAsset?
    /// Procursus ships one dependency package; other bootstraps need the list.
    public var procursus: Bool

    public init(
        destination: String,
        scope: InstallScope = .theosAndSDK,
        sdkAsset: SDKAsset? = nil,
        procursus: Bool = false
    ) {
        self.destination = destination
        self.scope = scope
        self.sdkAsset = sdkAsset
        self.procursus = procursus
    }
}

public struct TheosInstallPlan: Equatable, Sendable {
    public var steps: [InstallStep]
    /// Things the user needs to know, not failures of the plan itself.
    public var warnings: [String]
    /// Tools the plan wanted and could not find.
    public var missingTools: [String]

    public var needsRoot: Bool { steps.contains { $0.requiresRoot } }
}

/// Collects the parts of a plan while it is being built.
///
/// A class rather than a set of `inout` parameters on purpose: the plan used to
/// pass `warnings` as `inout` *and* call a closure that appended to the same
/// variable, which Swift catches at runtime as an overlapping access — it aborts
/// with "Fatal access conflict detected", and it is the kind of bug that only
/// shows up when the branch is taken.
final class InstallPlanBuilder {
    private(set) var steps: [InstallStep] = []
    private(set) var warnings: [String] = []
    private(set) var missingTools: [String] = []
    let toolPaths: [String: String]

    init(toolPaths: [String: String]) {
        self.toolPaths = toolPaths
    }

    func add(_ step: InstallStep) {
        steps.append(step)
    }

    func warn(_ message: String) {
        warnings.append(message)
    }

    /// Reports a tool the plan needs and cannot find, once per tool.
    func require(_ tool: String, because reason: String) -> Bool {
        if toolPaths[tool] != nil { return true }
        if !missingTools.contains(tool) { missingTools.append(tool) }
        warnings.append("\(tool) is not installed, so \(reason) cannot run.")
        return false
    }
}

public enum SDKFetchError: LocalizedError {
    case noAssets
    case malformed

    public var errorDescription: String? {
        switch self {
        case .noAssets:
            return "The theos/sdks release has no iPhoneOS SDK asset."
        case .malformed:
            return "The response was not a model list this app can read. It expects {\"data\":[{\"id\": …}]}, which is what the OpenAI protocol specifies."
        }
    }
}

/// Plans an on-device Theos installation.
///
/// This mirrors what the official installer does on a jailbroken device, split
/// along the lines that actually matter: the *dependencies* come from the package
/// manager and need root; Theos and its SDK are files in a folder and do not; and
/// the SDK does not care whether the checkout is healthy, so one button fetches
/// it on its own.
public enum TheosInstaller {

    public static let repository = "https://github.com/theos/theos.git"

    /// The packages the official installer pulls in on a bootstrap that is not
    /// Procursus, where there is no single `theos-dependencies` package.
    public static let dependencyPackages = [
        "ca-certificates", "clang", "coreutils", "curl", "dpkg", "git", "grep",
        "ldid", "make", "odcctools", "perl", "rsync", "xz",
    ]

    /// - Parameters:
    ///   - exists: answers "is there a file here?"
    ///   - listDirectory: returns a directory's entries, empty when it is absent.
    ///     Used to tell an empty destination (clone into it) from a directory that
    ///     already holds something (cloning into it would fail halfway).
    public static func plan(
        options: TheosInstallOptions,
        toolPaths: [String: String],
        privileges: PrivilegeContext,
        exists: (String) -> Bool = { _ in false },
        listDirectory: (String) -> [String] = { _ in [] }
    ) -> TheosInstallPlan {
        let builder = InstallPlanBuilder(toolPaths: toolPaths)

        if options.scope == .dependenciesOnly || options.scope == .theosAndSDK {
            dependencySteps(builder, options: options, privileges: privileges)
        }
        if options.scope == .theosAndSDK {
            theosSteps(
                builder,
                destination: options.destination,
                privileges: privileges,
                exists: exists,
                listDirectory: listDirectory
            )
        }
        if options.scope == .theosAndSDK || options.scope == .sdkOnly {
            sdkSteps(builder, destination: options.destination, asset: options.sdkAsset, privileges: privileges)
        }

        return TheosInstallPlan(
            steps: builder.steps,
            warnings: builder.warnings,
            missingTools: builder.missingTools
        )
    }

    // MARK: - Dependencies (the only part that needs root)

    private static func dependencySteps(
        _ builder: InstallPlanBuilder,
        options: TheosInstallOptions,
        privileges: PrivilegeContext
    ) {
        guard privileges.canEscalate else {
            builder.warn("The dependency packages (clang, ldid, dpkg, make, perl, git…) need root and this app has no way to become root. Install them from Sileo instead — this app cannot.")
            return
        }
        guard builder.require("apt-get", because: "the dependency packages") else { return }

        let packages = options.procursus ? ["theos-dependencies"] : dependencyPackages
        builder.add(InstallStep(
            label: "Updating package lists",
            kind: .command(tool: "apt-get", arguments: ["update"]),
            requiresRoot: true,
            tolerateFailure: true,
            note: "Failure here is not fatal: an unreachable repository and a broken one look the same from here."
        ))
        builder.add(InstallStep(
            label: "Installing \(packages.joined(separator: ", "))",
            kind: .command(tool: "apt-get", arguments: ["install", "-y"] + packages),
            requiresRoot: true
        ))
    }

    // MARK: - Theos itself

    private static func theosSteps(
        _ builder: InstallPlanBuilder,
        destination: String,
        privileges: PrivilegeContext,
        exists: (String) -> Bool,
        listDirectory: (String) -> [String]
    ) {
        let makefiles = destination + "/makefiles/common.mk"
        let needsRoot = destination == "/var/jb" || destination.hasPrefix("/var/jb/")
        if needsRoot && !privileges.canEscalate {
            builder.warn("\(destination) is inside the Dopamine bootstrap and needs root. Install passwordless sudo or run TheosStudio as root, then retry.")
            return
        }
        let alreadyThere = exists(makefiles)
        let entries = listDirectory(destination)

        if builder.require("mkdir", because: "the Theos directory") {
            builder.add(InstallStep(
                label: "Create \(destination)",
                kind: .command(tool: "mkdir", arguments: ["-p", destination]),
                requiresRoot: needsRoot,
                skipIfExists: destination
            ))
        }

        if alreadyThere {
            if exists(destination + "/.git") {
                builder.add(InstallStep(
                    label: "Repair Theos submodules",
                    kind: .command(tool: "git", arguments: ["-C", destination, "submodule", "update", "--init", "--recursive"]),
                    requiresRoot: needsRoot,
                    // Not fatal: an unreachable GitHub or an odd git state must not
                    // stop the SDK from arriving, which is the part that unblocks a
                    // build.
                    tolerateFailure: true,
                    note: "The submodules are the Logos preprocessor and the headers. A no-op when they are already there."
                ))
            } else {
                builder.warn("Theos is present but has no .git directory, so its submodules cannot be checked or updated. If a build complains that Logos is missing, install Theos again into an empty folder.")
            }
            return
        }

        // A directory holding something else cannot be cloned into — git refuses —
        // and emptying someone's folder to make room is not this app's decision.
        if !entries.isEmpty {
            builder.warn("\(destination) already contains \(entries.count) item\(entries.count == 1 ? "" : "s") and is not a Theos checkout. Move it aside, or install into a different folder — this app will not delete anything.")
            return
        }

        guard builder.require("git", because: "cloning Theos") else { return }
        builder.add(InstallStep(
            label: "Clone Theos",
            kind: .command(tool: "git", arguments: ["clone", "--recursive", repository, destination]),
            requiresRoot: needsRoot,
            skipIfExists: makefiles,
            note: "The submodules are the Logos preprocessor, the headers and the templates — without them nothing builds."
        ))
    }

    // MARK: - The SDK

    private static func sdkSteps(
        _ builder: InstallPlanBuilder,
        destination: String,
        asset: SDKAsset?,
        privileges: PrivilegeContext
    ) {
        let needsRoot = destination == "/var/jb" || destination.hasPrefix("/var/jb/")
        if needsRoot && !privileges.canEscalate {
            builder.warn("\(destination) is inside the Dopamine bootstrap and the SDK install needs root. Install passwordless sudo or run TheosStudio as root, then retry.")
            return
        }
        guard let asset else {
            builder.warn("No SDK was selected, so Theos would be left without one — and Theos cannot compile anything without an SDK in $THEOS/sdks.")
            return
        }

        let sdkDirectory = destination + "/sdks"
        let archive = sdkDirectory + "/." + asset.name + ".tar.xz"
        let installed = sdkDirectory + "/" + asset.name

        if builder.require("mkdir", because: "the SDK directory") {
            builder.add(InstallStep(
                label: "Create \(sdkDirectory)",
                kind: .command(tool: "mkdir", arguments: ["-p", sdkDirectory]),
                requiresRoot: needsRoot,
                skipIfExists: sdkDirectory
            ))
        }

        // The download needs no tool: the app fetches it with its own networking.
        builder.add(InstallStep(
            label: "Download \(asset.name) (\(asset.version))",
            kind: .download(url: asset.url, to: archive),
            skipIfExists: installed,
            note: "A patched SDK from theos/sdks, the same release the official installer uses."
        ))

        guard builder.require("tar", because: "unpacking the SDK") else { return }
        builder.add(InstallStep(
            label: "Unpack \(asset.name)",
            kind: .command(tool: "tar", arguments: ["-xJf", archive, "-C", sdkDirectory]),
            requiresRoot: needsRoot,
            skipIfExists: installed,
            tolerateFailure: true,
            note: "If this tar was built without xz support, the next step decompresses first."
        ))

        // The fallback ladder: every rung is skipped once the SDK is in place, so
        // the first one that works ends the sequence.
        guard builder.toolPaths["xz"] != nil else {
            builder.warn("xz is not installed, so if this device's tar was built without xz support the SDK cannot be unpacked. Installing xz-utils from Sileo fixes that.")
            return
        }
        builder.add(InstallStep(
            label: "Decompress \(asset.name)",
            kind: .command(tool: "xz", arguments: ["-d", archive]),
            requiresRoot: needsRoot,
            skipIfExists: installed,
            tolerateFailure: true
        ))
        builder.add(InstallStep(
            label: "Unpack \(asset.name) (after decompression)",
            kind: .command(tool: "tar", arguments: ["-xf", sdkDirectory + "/." + asset.name + ".tar", "-C", sdkDirectory]),
            requiresRoot: needsRoot,
            skipIfExists: installed,
            note: "This device's tar has no xz support, so xz did it."
        ))
    }

    // MARK: - SDK discovery

    /// Picks the newest iPhoneOS SDK from a `theos/sdks` release response.
    public static func latestSDKAsset(fromReleaseJSON data: Data) throws -> SDKAsset {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
            let assets: [Asset]
        }

        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw SDKFetchError.malformed
        }

        let candidates = release.assets.compactMap { asset -> SDKAsset? in
            guard asset.name.hasPrefix("iPhoneOS"), asset.name.hasSuffix(".sdk.tar.xz") else { return nil }
            let name = String(asset.name.dropLast(".tar.xz".count))
            guard let version = version(fromSDKName: name) else { return nil }
            return SDKAsset(name: name, url: asset.browser_download_url, version: version)
        }

        guard let newest = candidates.max(by: { compareVersions($0.version, $1.version) < 0 }) else {
            throw SDKFetchError.noAssets
        }
        return newest
    }

    /// `iPhoneOS16.5.sdk` -> `16.5`.
    public static func version(fromSDKName name: String) -> String? {
        guard name.hasPrefix("iPhoneOS"), name.hasSuffix(".sdk") else { return nil }
        let start = name.index(name.startIndex, offsetBy: "iPhoneOS".count)
        let end = name.index(name.endIndex, offsetBy: -".sdk".count)
        let version = String(name[start..<end])
        return version.isEmpty ? nil : version
    }

    /// Numeric, component-wise: `16.5` is newer than `9.3`, which a string
    /// comparison gets backwards.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    /// The `theos/sdks` release endpoint `install-sdk` itself uses.
    public static let sdkReleaseURL = URL(string: "https://api.github.com/repos/theos/sdks/releases/latest")!
}
