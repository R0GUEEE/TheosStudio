import Foundation

/// The kind of Theos project a folder holds. Mirrors the `nic.pl` templates the
/// app can generate, restricted to the ones that make sense on a device.
public enum ProjectKind: String, Codable, CaseIterable, Sendable {
    case tweak
    case tweakWithPreferences
    case preferenceBundle
    case application
    case tool

    public var displayName: String {
        switch self {
        case .tweak: return "Tweak"
        case .tweakWithPreferences: return "Tweak + Preferences"
        case .preferenceBundle: return "Preference Bundle"
        case .application: return "Application"
        case .tool: return "Command Line Tool"
        }
    }

    public var summary: String {
        switch self {
        case .tweak:
            return "A dylib injected into SpringBoard or an app by Logos hooks."
        case .tweakWithPreferences:
            return "A tweak plus a preference bundle, wired together with SUBPROJECTS."
        case .preferenceBundle:
            return "A settings panel for an existing tweak, loaded by PreferenceLoader."
        case .application:
            return "A standalone .app installed into /Applications."
        case .tool:
            return "A plain executable installed into /usr/local/bin."
        }
    }

    /// True when the build links a hooking library, which the control file then
    /// has to depend on.
    public var needsHookingLibrary: Bool {
        switch self {
        case .tweak, .tweakWithPreferences: return true
        case .preferenceBundle, .application, .tool: return false
        }
    }

    /// True when Theos needs a filter plist next to the Makefile.
    public var usesInjectionFilter: Bool {
        switch self {
        case .tweak, .tweakWithPreferences: return true
        case .preferenceBundle, .application, .tool: return false
        }
    }

    /// The Theos makefile fragment that carries the build rules.
    public var makefileFragment: String {
        switch self {
        case .tweak, .tweakWithPreferences: return "tweak.mk"
        case .preferenceBundle: return "bundle.mk"
        case .application: return "application.mk"
        case .tool: return "tool.mk"
        }
    }

    public var systemImage: String {
        switch self {
        case .tweak: return "wand.and.stars"
        case .tweakWithPreferences: return "slider.horizontal.3"
        case .preferenceBundle: return "gearshape.2"
        case .application: return "app.badge"
        case .tool: return "terminal"
        }
    }
}

/// A file to write when a project is created.
public struct TemplateFile: Equatable, Sendable {
    /// Path relative to the project root, using `/` separators.
    public let path: String
    public let contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

/// Everything the templates need to render a project.
public struct TemplateRequest: Equatable, Sendable {
    /// The project (and `TWEAK_NAME`) identifier: `MyTweak`.
    public var name: String
    public var kind: ProjectKind
    public var scheme: PackagingScheme
    /// Reverse-DNS identifier, e.g. `com.example.mytweak`.
    public var packageIdentifier: String
    public var authorName: String
    public var authorEmail: String
    /// Short description for the control file and the generated README.
    public var summary: String
    public var minimumIOSVersion: String
    /// Bundle the tweak injects into, `com.apple.springboard` by default.
    public var injectionBundle: String
    /// Add `DEBUG = 0`-style release flags hints to the README.
    public var architectures: [String]

    public init(
        name: String,
        kind: ProjectKind,
        scheme: PackagingScheme,
        packageIdentifier: String,
        authorName: String = "Your Name",
        authorEmail: String = "you@example.com",
        summary: String = "A Theos project built on device with TheosStudio.",
        minimumIOSVersion: String = "15.0",
        injectionBundle: String = "com.apple.springboard",
        architectures: [String] = ["arm64", "arm64e"]
    ) {
        self.name = name
        self.kind = kind
        self.scheme = scheme
        self.packageIdentifier = packageIdentifier
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.summary = summary
        self.minimumIOSVersion = minimumIOSVersion
        self.injectionBundle = injectionBundle
        self.architectures = architectures
    }

    /// The control file for this request.
    public func controlFile() -> ControlFile {
        var control = ControlFile()
        control["Package"] = packageIdentifier
        control["Name"] = name
        control["Version"] = "0.0.1"
        control["Architecture"] = scheme.debianArchitecture
        control["Description"] = summary
        control["Maintainer"] = "\(authorName) <\(authorEmail)>"
        control["Author"] = "\(authorName) <\(authorEmail)>"
        switch kind {
        case .tweak, .tweakWithPreferences:
            control["Section"] = "Tweaks"
            control["Depends"] = "mobilesubstrate"
        case .preferenceBundle:
            control["Section"] = "Tweaks"
            control["Depends"] = "preferenceloader"
        case .application:
            control["Section"] = "Applications"
        case .tool:
            control["Section"] = "Utilities"
        }
        return control
    }
}

/// Reads what a project *is* back out of its files, so the app can label a
/// folder the user dropped in by hand without a manifest of its own.
public struct ProjectManifest: Equatable, Sendable {
    public var name: String?
    public var kind: ProjectKind?
    public var packageIdentifier: String?
    public var version: String?
    public var declaredScheme: PackagingScheme?

    public init(
        name: String? = nil,
        kind: ProjectKind? = nil,
        packageIdentifier: String? = nil,
        version: String? = nil,
        declaredScheme: PackagingScheme? = nil
    ) {
        self.name = name
        self.kind = kind
        self.packageIdentifier = packageIdentifier
        self.version = version
        self.declaredScheme = declaredScheme
    }

    public static func parse(makefile: String, control: String) -> ProjectManifest {
        var manifest = ProjectManifest()
        let controlFile = ControlFile.parse(control)
        manifest.packageIdentifier = controlFile.packageIdentifier
        manifest.version = controlFile.version

        var declaredName: String?
        var isApplication = false
        var isTool = false
        var isBundle = false
        var hasSubprojects = false

        for rawLine in makefile.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }

            if let value = assignmentValue(in: line, name: "THEOS_PACKAGE_SCHEME") {
                manifest.declaredScheme = PackagingScheme(rawValue: value)
            }
            if let value = assignmentValue(in: line, name: "TWEAK_NAME") {
                declaredName = declaredName ?? value
            }
            if let value = assignmentValue(in: line, name: "APPLICATION_NAME") {
                declaredName = declaredName ?? value
                isApplication = true
            }
            if let value = assignmentValue(in: line, name: "TOOL_NAME") {
                declaredName = declaredName ?? value
                isTool = true
            }
            if let value = assignmentValue(in: line, name: "BUNDLE_NAME") {
                declaredName = declaredName ?? value
                isBundle = true
            }
            if line.hasPrefix("SUBPROJECTS") { hasSubprojects = true }
            if line.contains("aggregate.mk") { hasSubprojects = true }
            // The `include .../tweak.mk` (or bundle.mk, application.mk, tool.mk)
            // line is what actually decides what is being built; the name
            // variable only says what it is called.
            if let kind = ProjectKind.allCases.first(where: { line.contains("/\($0.makefileFragment)") }) {
                manifest.kind = manifest.kind ?? kind
            }
        }

        if isTool {
            manifest.kind = .tool
        } else if isApplication {
            manifest.kind = .application
        } else if isBundle {
            manifest.kind = .preferenceBundle
        } else if manifest.kind == .tweak && hasSubprojects {
            manifest.kind = .tweakWithPreferences
        }

        manifest.name = declaredName
        return manifest
    }

    /// Reads `NAME = value`, `NAME := value`, `export NAME = value`. Returns nil
    /// when the line assigns something else.
    static func assignmentValue(in line: String, name: String) -> String? {
        var text = line
        if text.hasPrefix("export ") {
            text = String(text.dropFirst("export ".count))
        }
        for separator in [":=", "+=", "?=", "="] {
            guard let range = text.range(of: separator) else { continue }
            let key = text[text.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            guard key == name else { continue }
            var value = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            // A trailing `# comment` is not part of the value.
            if let hash = value.range(of: " #") {
                value = String(value[value.startIndex..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return value
        }
        return nil
    }
}
