import Foundation

/// A process it is worth restarting after installing.
public struct LaunchTarget: Equatable, Sendable, Identifiable {
    public enum Source: String, Equatable, Sendable {
        case installTargetProcesses
        case injectionFilter
    }

    public var name: String
    public var source: Source
    public var bundleIdentifier: String?

    public var id: String { name }

    /// Respringing is the sledgehammer; killing one app is how you test a hook
    /// inside it without waiting for SpringBoard to come back.
    public var detail: String {
        switch source {
        case .installTargetProcesses:
            return "Listed in INSTALL_TARGET_PROCESSES, so this is what Theos restarts too."
        case .injectionFilter:
            return "The injection filter targets \(bundleIdentifier ?? "it"), which is this process."
        }
    }
}

/// Works out what to restart after an install.
///
/// `INSTALL_TARGET_PROCESSES` is authoritative — it is the list Theos itself
/// restarts — and the injection filter says which app the tweak is for, so the
/// two together answer "what do I relaunch to see this take effect".
public enum LaunchTargets {

    /// Bundle identifiers whose process name is not obvious from the identifier.
    /// Deliberately short: a wrong guess here kills something unrelated, so an
    /// unknown bundle simply contributes no target.
    static let knownProcessNames: [String: String] = [
        "com.apple.springboard": "SpringBoard",
        "com.apple.backboardd": "backboardd",
        "com.apple.prefs": "Preferences",
        "com.apple.preferences": "Preferences",
        "com.apple.mobilesafari": "MobileSafari",
        "com.apple.mobilemail": "MobileMail",
        "com.apple.mobilesms": "MobileSMS",
        "com.apple.music": "Music",
        "com.apple.camera": "Camera",
        "com.apple.mobilephone": "MobilePhone",
        "com.apple.mobiletimer": "MobileTimer",
        "com.apple.controlcenter": "ControlCenter",
        "com.apple.clock": "MobileTimer",
    ]

    public static func targets(inMakefile makefile: String, filterPlist: String?) -> [LaunchTarget] {
        var targets: [LaunchTarget] = []
        var seen = Set<String>()

        if let value = ProjectManifest.assignmentValue(in: makefile, name: "INSTALL_TARGET_PROCESSES") {
            for name in value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) where !name.isEmpty {
                // A process name is case sensitive to killall, so it is kept as
                // written rather than normalised.
                if seen.insert(name).inserted {
                    targets.append(LaunchTarget(name: name, source: .installTargetProcesses, bundleIdentifier: nil))
                }
            }
        }

        for identifier in bundleIdentifiers(inFilterPlist: filterPlist) {
            guard let process = knownProcessNames[identifier.lowercased()] else { continue }
            if seen.insert(process).inserted {
                targets.append(LaunchTarget(name: process, source: .injectionFilter, bundleIdentifier: identifier))
            }
        }

        return targets
    }

    /// The `Bundles = ( "a", "b" );` list of an injection filter — an old-style
    /// plist, so it is scanned rather than parsed.
    public static func bundleIdentifiers(inFilterPlist plist: String?) -> [String] {
        guard let plist else { return [] }
        var identifiers: [String] = []
        var remainder = Substring(plist)

        while let range = remainder.range(of: "\"") {
            let after = remainder[range.upperBound...]
            guard let close = after.firstIndex(of: "\"") else { break }
            let candidate = String(after[after.startIndex..<close])
            // Bundle identifiers only: the filter's own keys are quoted too.
            if candidate.contains("."), !candidate.contains(" ") {
                identifiers.append(candidate)
            }
            remainder = after[after.index(after: close)...]
        }
        return identifiers
    }
}
