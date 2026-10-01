import Foundation

/// One executable the build needs, and what happens without it.
public struct TheosTool: Equatable, Sendable {
    /// Executable name as it is looked up on `PATH`.
    public let name: String
    public let purpose: String
    public let required: Bool
    /// Packages that provide it, for the "install what is missing" command.
    public let packages: [String]

    public init(name: String, purpose: String, required: Bool, packages: [String]) {
        self.name = name
        self.purpose = purpose
        self.required = required
        self.packages = packages
    }
}

public struct ToolStatus: Equatable, Sendable {
    public let tool: TheosTool
    /// Absolute path the tool was found at, `nil` when it is missing.
    public let path: String?

    public init(tool: TheosTool, path: String?) {
        self.tool = tool
        self.path = path
    }

    public var isInstalled: Bool { path != nil }
}

/// The result of looking for Theos and its tools on this device.
public struct ToolchainReport: Equatable, Sendable {
    public var jailbreak: JailbreakLayout
    public var theosRoot: String?
    /// `true` when the root came from the app's settings rather than from a probe.
    public var theosRootWasOverridden: Bool
    public var binDirectories: [String]
    public var statuses: [ToolStatus]
    /// Directories inside `$THEOS/sdks`.
    public var sdkDirectories: [String]
    public var notes: [String]

    public var missingRequired: [ToolStatus] { statuses.filter { $0.tool.required && !$0.isInstalled } }
    public var missingOptional: [ToolStatus] { statuses.filter { !$0.tool.required && !$0.isInstalled } }

    /// A build can only work with Theos itself, an SDK, and every required tool.
    public var isReadyToBuild: Bool {
        theosRoot != nil && !sdkDirectories.isEmpty && missingRequired.isEmpty
    }

    /// The missing packages, deduplicated, in a stable order.
    public var missingPackages: [String] {
        var seen = Set<String>()
        var packages: [String] = []
        for status in missingRequired {
            for package in status.tool.packages where !seen.contains(package) {
                seen.insert(package)
                packages.append(package)
            }
        }
        return packages
    }

    /// What the user would have to type to make this device able to build.
    public var installCommand: String {
        let packages = missingPackages
        guard !packages.isEmpty else { return "" }
        return "apt-get update && apt-get install -y " + packages.joined(separator: " ")
    }

    public func status(for name: String) -> ToolStatus? {
        statuses.first { $0.tool.name == name }
    }
}

/// Finds Theos and the executables it drives, without running anything.
///
/// Every filesystem question goes through an injected closure so the search order
/// — which is the part that actually breaks on devices — is testable.
public enum TheosLocator {

    /// The tools a build needs. `clang` is what Theos compiles with; `ldid` signs
    /// the result; `dpkg-deb` builds the .deb; `perl` runs Logos, which is a Perl
    /// script and therefore required for any tweak.
    public static let tools: [TheosTool] = [
        TheosTool(name: "make", purpose: "build driver Theos runs under", required: true, packages: ["make"]),
        TheosTool(name: "clang", purpose: "compiler for the tweak and its objects", required: true, packages: ["clang"]),
        TheosTool(name: "ldid", purpose: "signs the dylib so the injector will load it", required: true, packages: ["ldid"]),
        TheosTool(name: "dpkg-deb", purpose: "packages the .deb file", required: true, packages: ["dpkg"]),
        TheosTool(name: "dpkg", purpose: "installs the .deb on the device", required: true, packages: ["dpkg"]),
        TheosTool(name: "perl", purpose: "runs Logos, the %hook preprocessor", required: true, packages: ["perl"]),
        TheosTool(name: "killall", purpose: "restarts SpringBoard after an install", required: false, packages: ["procps"]),
        TheosTool(name: "sbreload", purpose: "soft respring without dropping the UI", required: false, packages: ["sbreload"]),
        TheosTool(name: "uicache", purpose: "registers newly installed apps", required: false, packages: ["uikittools"]),
        TheosTool(name: "git", purpose: "clones Theos and SDK repositories", required: false, packages: ["git"]),
        TheosTool(name: "ssh", purpose: "installs over the network on a remote device", required: false, packages: ["openssh-client"]),
    ]

    /// Where a Theos checkout may live, most likely first. `/var/jb/opt/theos` is
    /// the Procursus location, `/opt/theos` the classic one.
    public static func defaultTheosRoots(home: String, jailbreak: JailbreakLayout) -> [String] {
        var roots: [String] = []
        if let prefix = jailbreak.rootlessPrefix {
            roots += ["\(prefix)/opt/theos", "\(prefix)/usr/share/theos", "\(prefix)/usr/local/theos"]
        }
        roots += ["/opt/theos", "/usr/share/theos", "/usr/local/theos", "/var/theos"]
        roots += ["\(home)/theos", "\(home)/.theos", "/var/mobile/theos", "/var/root/theos"]
        return roots
    }

    /// A directory is a Theos root when it has the makefiles Theos includes from.
    public static func isTheosRoot(_ path: String, exists: (String) -> Bool) -> Bool {
        exists(path + "/makefiles/common.mk")
    }

    public static func locateTheos(roots: [String], exists: (String) -> Bool) -> String? {
        roots.first { isTheosRoot($0, exists: exists) }
    }

    /// Directories to put on `PATH`, most specific first.
    public static func binDirectories(jailbreak: JailbreakLayout, theosRoot: String?) -> [String] {
        var directories = jailbreak.binDirectories
        if let theosRoot {
            directories.append(theosRoot + "/bin")
            directories.append(theosRoot + "/toolchain/linux/iphone/bin")
            directories.append(theosRoot + "/toolchain/iphone/bin")
        }
        return directories
    }

    public static func resolve(executable: String, in directories: [String], exists: (String) -> Bool) -> String? {
        directories.first { exists($0 + "/" + executable) }.map { $0 + "/" + executable }
    }

    /// `PATH` and the rest of the environment Theos is invoked with.
    public static func environment(
        theosRoot: String,
        binDirectories: [String],
        base: [String: String],
        home: String
    ) -> [String: String] {
        var environment = base
        var pathComponents = binDirectories
        pathComponents.append(theosRoot + "/bin")
        if let existing = base["PATH"] {
            pathComponents += existing.split(separator: ":").map(String.init)
        }
        var seen = Set<String>()
        let path = pathComponents.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        environment["PATH"] = path
        environment["THEOS"] = theosRoot
        environment["HOME"] = home
        // Deterministic output: make and clang both change their messages with
        // the locale, and the app parses those messages.
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        return environment
    }

    /// Probes the device. `exists` answers "is there a file here?", `listDirectory`
    /// returns the entries of a directory (empty when it does not exist).
    public static func report(
        home: String,
        override: String?,
        jailbreak: JailbreakLayout,
        base: [String: String] = ProcessInfo.processInfo.environment,
        exists: (String) -> Bool,
        listDirectory: (String) -> [String]
    ) -> ToolchainReport {
        var notes: [String] = []
        var root: String?
        var overridden = false

        if let override, !override.isEmpty {
            if isTheosRoot(override, exists: exists) {
                root = override
                overridden = true
            } else {
                notes.append("The Theos path in Settings (\(override)) does not contain makefiles/common.mk — falling back to searching.")
            }
        }

        if root == nil, let fromEnvironment = base["THEOS"], isTheosRoot(fromEnvironment, exists: exists) {
            root = fromEnvironment
            notes.append("Using Theos from the THEOS environment variable (\(fromEnvironment)).")
        }

        if root == nil {
            root = locateTheos(roots: defaultTheosRoots(home: home, jailbreak: jailbreak), exists: exists)
        }

        let directories = binDirectories(jailbreak: jailbreak, theosRoot: root)
        let statuses = tools.map { tool in
            ToolStatus(tool: tool, path: resolve(executable: tool.name, in: directories, exists: exists))
        }

        var sdkDirectories: [String] = []
        if let root {
            sdkDirectories = listDirectory(root + "/sdks")
                .filter { $0.hasSuffix(".sdk") }
                .sorted()
        } else {
            notes.append("Theos was not found. Install it (tap Install Theos) or point TheosStudio at an existing checkout in Settings.")
        }

        if root != nil && sdkDirectories.isEmpty {
            notes.append("Theos has no SDK in $THEOS/sdks. Theos cannot compile anything without one — the app's Toolchain tab can fetch one.")
        }

        let missingRequired = statuses.filter { $0.tool.required && !$0.isInstalled }
        if !missingRequired.isEmpty {
            notes.append("Missing: \(missingRequired.map(\.tool.name).joined(separator: ", ")). Everything Theos drives has to exist on the device — there is no host to fall back to.")
        }

        if jailbreak.rootlessPrefix == nil {
            notes.append("No /var/jb found: this looks like a rootful jailbreak, so new projects default to the rootful scheme.")
        }

        return ToolchainReport(
            jailbreak: jailbreak,
            theosRoot: root,
            theosRootWasOverridden: overridden,
            binDirectories: directories,
            statuses: statuses,
            sdkDirectories: sdkDirectories,
            notes: notes
        )
    }
}
