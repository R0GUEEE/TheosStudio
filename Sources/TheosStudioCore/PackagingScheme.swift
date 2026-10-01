import Foundation

/// How a package is laid out on the device.
///
/// Theos takes the whole decision from `THEOS_PACKAGE_SCHEME`: it rewrites every
/// install path in `layout/` and in the tweak's own install rules, and it stamps
/// the right `Architecture:` field into the .deb. The app never rewrites paths
/// itself — it only sets the variable and reports what the scheme means.
public enum PackagingScheme: String, Codable, CaseIterable, Sendable {
    /// Classic jailbreaks (unc0ver, checkra1n, palera1n rootful): everything at `/`.
    case rootful
    /// Modern bootstraps (Procursus/ElleKit, Dopamine, palera1n rootless): `/var/jb`.
    case rootless
    /// roothide bootstraps: a per-boot randomised prefix, resolved with `jbroot()`.
    case roothide

    /// The value Theos expects in `THEOS_PACKAGE_SCHEME`. Rootful is the absence
    /// of the variable, not a value, so it is `nil` here.
    public var theosVariableValue: String? {
        switch self {
        case .rootful: return nil
        case .rootless: return "rootless"
        case .roothide: return "roothide"
        }
    }

    /// The `Architecture:` field Theos writes into the control file.
    public var debianArchitecture: String {
        switch self {
        case .rootful: return "iphoneos-arm"
        case .rootless: return "iphoneos-arm64"
        case .roothide: return "iphoneos-arm64e"
        }
    }

    /// Where a package installs to, for display purposes. roothide resolves this
    /// at runtime, so there is no fixed answer.
    public var installRootDescription: String {
        switch self {
        case .rootful: return "/"
        case .rootless: return "/var/jb"
        case .roothide: return "jbroot() (randomised per boot)"
        }
    }

    public var displayName: String {
        switch self {
        case .rootful: return "Rootful"
        case .rootless: return "Rootless"
        case .roothide: return "roothide"
        }
    }

    public var summary: String {
        switch self {
        case .rootful:
            return "Installs to /. For checkra1n, unc0ver, palera1n --rootful."
        case .rootless:
            return "Installs to /var/jb. For Dopamine, palera1n, and every Procursus bootstrap."
        case .roothide:
            return "Randomised prefix resolved at runtime. Needs the roothide Theos fork."
        }
    }

    /// True when the scheme needs the roothide Theos fork rather than upstream
    /// Theos. The app warns instead of producing a package that cannot work.
    public var requiresRoothideTheos: Bool { self == .roothide }

    /// The default scheme for a device: rootless where `/var/jb` exists, rootful
    /// otherwise. `jailbreakRootExists` is injected so this stays a pure function.
    public static func detected(jailbreakRootExists: Bool) -> PackagingScheme {
        jailbreakRootExists ? .rootless : .rootful
    }
}

/// The jailbreak layout the app is running on.
public struct JailbreakLayout: Equatable, Sendable {
    /// `/var/jb` on rootless bootstraps, `nil` on rootful ones.
    public let rootlessPrefix: String?
    /// Detected scheme, used as the default for new projects.
    public let scheme: PackagingScheme

    public init(rootlessPrefix: String?, scheme: PackagingScheme) {
        self.rootlessPrefix = rootlessPrefix
        self.scheme = scheme
    }

    /// Probes the filesystem for `/var/jb`.
    public static func detect(
        rootlessPrefix: String = "/var/jb",
        exists: (String) -> Bool
    ) -> JailbreakLayout {
        let present = exists(rootlessPrefix)
        return JailbreakLayout(
            rootlessPrefix: present ? rootlessPrefix : nil,
            scheme: PackagingScheme.detected(jailbreakRootExists: present)
        )
    }

    /// The directories a package manager's binaries live in, most specific first.
    public var binDirectories: [String] {
        var directories: [String] = []
        if let prefix = rootlessPrefix {
            directories += ["\(prefix)/usr/bin", "\(prefix)/bin", "\(prefix)/usr/sbin", "\(prefix)/sbin"]
        }
        directories += ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin"]
        return directories
    }
}
