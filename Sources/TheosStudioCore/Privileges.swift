import Foundation

/// How this process can run something as root, if at all.
///
/// An app installed from a .deb is launched by SpringBoard as `mobile`. That is
/// enough to write a project and run `make`, and it is not enough to run
/// `apt-get` or `dpkg`: the bootstrap's directories belong to root. So every
/// privileged action goes through here, and when there is no way to escalate the
/// app says so instead of reporting a permission error as a build failure.
public struct PrivilegeContext: Equatable, Sendable {

    public enum Mode: Equatable, Sendable {
        /// Already root — either launched that way or the jailbreak launches
        /// /Applications apps as root.
        case root
        /// `sudo` exists and runs without asking for a password. The path is kept
        /// because the bootstrap's sudo is not the same file on every jailbreak.
        case sudo(path: String)
        /// No way to escalate. Privileged actions will fail; the app must say
        /// which command to run instead.
        case unprivileged
    }

    public let mode: Mode

    public init(mode: Mode) {
        self.mode = mode
    }

    public var isRoot: Bool { mode == .root }

    public var sudoPath: String? {
        if case .sudo(let path) = mode { return path }
        return nil
    }

    /// True when a privileged command has a chance of working.
    public var canEscalate: Bool { isRoot || sudoPath != nil }

    /// `sudo -n`, never a bare `sudo`: an app has no terminal, so a password
    /// prompt would hang the build forever instead of failing.
    public var prefix: [String] {
        guard let sudoPath else { return [] }
        return [sudoPath, "-n"]
    }

    /// The executable and arguments to actually spawn.
    ///
    /// With sudo, `sudo` *is* the process and the tool is its argument; without
    /// it the tool is the process. Getting this the other way round silently runs
    /// the command unprivileged and turns a fixable permission problem into a
    /// confusing failure.
    public func wrapped(_ tool: String, _ arguments: [String]) -> (executable: String, arguments: [String]) {
        guard let sudoPath else { return (tool, arguments) }
        return (sudoPath, ["-n", tool] + arguments)
    }

    /// One line for the UI.
    public var summary: String {
        switch mode {
        case .root:
            return "root — packages can be installed directly."
        case .sudo(let path):
            return "sudo without a password (\(path)) — privileged commands are run through it."
        case .unprivileged:
            return "mobile, with no passwordless sudo — this app cannot install packages."
        }
    }

    /// What to tell the user when something needs root and cannot have it. The
    /// command is included verbatim so it can be pasted into a terminal.
    public func remedy(for command: String) -> String {
        """
        This needs root, and this app is running as mobile without passwordless \
        sudo. Three ways forward:

        1. Install sudo if the bootstrap has it (`apt install sudo` from a root \
        shell), then run the command again here.
        2. Run it yourself in a terminal on the device:
           \(command)
        3. Install the package from Sileo or Zebra instead — the Share button on \
        a built package hands the .deb straight to them.
        """
    }
}

/// Decides the mode from two facts about the device.
///
/// Deliberately pure: "is sudo passwordless here?" is the question that decides
/// whether the app can install anything, and that is worth a test.
public enum PrivilegeResolver {

    public static func resolve(
        isRoot: Bool,
        sudoPath: String?,
        sudoIsPasswordless: Bool
    ) -> PrivilegeContext {
        if isRoot {
            return PrivilegeContext(mode: .root)
        }
        if let sudoPath, sudoIsPasswordless {
            return PrivilegeContext(mode: .sudo(path: sudoPath))
        }
        return PrivilegeContext(mode: .unprivileged)
    }
}
