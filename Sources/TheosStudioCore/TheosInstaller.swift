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

public struct TheosInstallOptions: Equatable, Sendable {
    /// Where Theos goes. A path the app can write: installing Theos into the
    /// bootstrap needs root, and Theos explicitly refuses to be installed or run
    /// as root, so a directory in the app's own document folder is the right
    /// answer, not a compromise.
    public var destination: String
    /// Install the packages Theos needs (clang, ldid, dpkg, make, perl, git…).
    /// This is the only part that needs root.
    public var installDependencies: Bool
    public var fetchSDK: Bool
    /// Resolved from the GitHub API by the caller; the plan only places it.
    public var sdkAsset: SDKAsset?
    /// Procursus ships one dependency package; other bootstraps need the list.
    public var procursus: Bool

    public init(
        destination: String,
        installDependencies: Bool = true,
        fetchSDK: Bool = true,
        sdkAsset: SDKAsset? = nil,
        procursus: Bool = false
    ) {
        self.destination = destination
        self.installDependencies = installDependencies
        self.fetchSDK = fetchSDK
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

public enum SDKFetchError: LocalizedError {
    case noAssets
    case malformed

    public var errorDescription: String? {
        switch self {
        case .noAssets:
            return "The theos/sdks release has no iPhoneOS SDK asset."
        case .malformed:
            return "The GitHub release response could not be read."
        }
    }
}

/// Plans an on-device Theos installation.
///
/// This mirrors what the official installer does on a jailbroken device, split
/// along the line that actually matters: the *dependencies* come from the package
/// manager and need root, while Theos itself and its SDK are files in a folder and
/// do not. When there is no way to escalate, the plan simply has no dependency
/// steps and says why — instead of failing halfway with a permission error.
public enum TheosInstaller {

    public static let repository = "https://github.com/theos/theos.git"

    /// The packages the official installer pulls in on a bootstrap that is not
    /// Procursus, where there is no single `theos-dependencies` package.
    public static let dependencyPackages = [
        "ca-certificates", "clang", "coreutils", "curl", "dpkg", "git", "grep",
        "ldid", "make", "odcctools", "perl", "rsync", "xz",
    ]

    public static func plan(
        options: TheosInstallOptions,
        toolPaths: [String: String],
        privileges: PrivilegeContext
    ) -> TheosInstallPlan {
        var steps: [InstallStep] = []
        var warnings: [String] = []
        var missing: [String] = []

        // Anything the plan needs but cannot find is reported once, by name.
        func require(_ tool: String, because reason: String) -> Bool {
            if toolPaths[tool] != nil { return true }
            if !missing.contains(tool) { missing.append(tool) }
            warnings.append("\(tool) is not installed, so \(reason) cannot run.")
            return false
        }

        if options.installDependencies {
            if privileges.canEscalate {
                if require("apt-get", because: "the dependency packages") {
                    let packages = options.procursus
                        ? ["theos-dependencies"]
                        : dependencyPackages
                    steps.append(InstallStep(
                        label: "Updating package lists",
                        kind: .command(tool: "apt-get", arguments: ["update"]),
                        requiresRoot: true,
                        note: "Failure here is not fatal: some repositories are unreachable and apt-get says so."
                    ))
                    steps.append(InstallStep(
                        label: "Installing \(packages.joined(separator: ", "))",
                        kind: .command(tool: "apt-get", arguments: ["install", "-y"] + packages),
                        requiresRoot: true,
                        note: "This is the part that needs root."
                    ))
                }
            } else {
                warnings.append(
                    "The dependency packages (clang, ldid, dpkg, make, perl, git…) need root and this app has no way to become root. Tap “Copy command” and run it from a root shell, or install them from Sileo."
                )
            }
        }

        let destination = options.destination
        let theosMakefiles = destination + "/makefiles/common.mk"
        // Reported through `require` so a missing git names itself in
        // missingTools and in the warnings, exactly like the other tools.
        let cloned = require("git", because: "Theos itself")

        if require("mkdir", because: "the Theos directory") {
            steps.append(InstallStep(
                label: "Create \(destination)",
                kind: .command(tool: "mkdir", arguments: ["-p", destination]),
                skipIfExists: destination
            ))
        }

        if cloned {
            steps.append(InstallStep(
                label: "Clone Theos",
                kind: .command(tool: "git", arguments: ["clone", "--recursive", repository, destination]),
                skipIfExists: theosMakefiles,
                note: "The submodules are the Logos preprocessor, the headers and the templates — without them nothing builds."
            ))
            steps.append(InstallStep(
                label: "Update Theos submodules",
                kind: .command(tool: "git", arguments: ["-C", destination, "submodule", "update", "--init", "--recursive"]),
                note: "A no-op after a fresh clone; it repairs a clone that was interrupted."
            ))
        }

        if options.fetchSDK {
            if let asset = options.sdkAsset {
                let sdkDirectory = destination + "/sdks"
                let archive = sdkDirectory + "/." + asset.name + ".tar.xz"
                let installed = sdkDirectory + "/" + asset.name

                if require("mkdir", because: "the SDK directory") {
                    steps.append(InstallStep(
                        label: "Create \(sdkDirectory)",
                        kind: .command(tool: "mkdir", arguments: ["-p", sdkDirectory]),
                        skipIfExists: sdkDirectory
                    ))
                }

                // The download needs no tool: the app fetches it.
                steps.append(InstallStep(
                    label: "Download \(asset.name) (\(asset.version))",
                    kind: .download(url: asset.url, to: archive),
                    skipIfExists: installed,
                    note: "A patched SDK from theos/sdks, the same release the official installer uses."
                ))

                if require("tar", because: "unpacking the SDK") {
                    steps.append(InstallStep(
                        label: "Unpack \(asset.name)",
                        kind: .command(tool: "tar", arguments: ["-xJf", archive, "-C", sdkDirectory]),
                        skipIfExists: installed,
                        tolerateFailure: true,
                        note: "If this tar was built without xz support the next step decompresses first."
                    ))
                    // The fallback ladder: each step is skipped once the SDK is in
                    // place, so the first one that works ends the sequence.
                    if toolPaths["xz"] != nil {
                        let decompressed = sdkDirectory + "/." + asset.name + ".tar"
                        steps.append(InstallStep(
                            label: "Decompress \(asset.name)",
                            kind: .command(tool: "xz", arguments: ["-d", archive]),
                            skipIfExists: installed,
                            tolerateFailure: true
                        ))
                        steps.append(InstallStep(
                            label: "Unpack \(asset.name) (after decompression)",
                            kind: .command(tool: "tar", arguments: ["-xf", decompressed, "-C", sdkDirectory]),
                            skipIfExists: installed,
                            note: "The device's tar has no xz support, so xz did it."
                        ))
                    } else {
                        warnings.append("xz is not installed, so if this device's tar was built without xz support the SDK cannot be unpacked. Installing xz-utils fixes that.")
                    }
                }
            } else {
                warnings.append("No SDK was selected, so Theos would be installed without one — and Theos cannot compile anything without an SDK in $THEOS/sdks.")
            }
        }

        if !cloned {
            warnings.append("git is what fetches Theos itself. Install it (it comes with the dependency packages) and try again.")
        } else if !steps.contains(where: { $0.requiresRoot }) && options.installDependencies && !privileges.canEscalate {
            warnings.append("Installing Theos itself does not need root, but building a tweak also needs clang, ldid, dpkg-deb and perl, and those come from the dependency packages.")
        }

        return TheosInstallPlan(steps: steps, warnings: warnings, missingTools: missing)
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
