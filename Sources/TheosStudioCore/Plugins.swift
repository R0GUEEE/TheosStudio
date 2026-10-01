import Foundation

public enum PluginScope: String, Codable, CaseIterable, Sendable {
    case global
    case project
}

public struct PluginAction: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var systemImage: String
    public var command: [String]
    public var requiresProject: Bool
    public var requiresPackage: Bool
    public var destructive: Bool

    public init(
        id: String,
        title: String,
        detail: String = "",
        systemImage: String = "terminal",
        command: [String],
        requiresProject: Bool = false,
        requiresPackage: Bool = false,
        destructive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.command = command
        self.requiresProject = requiresProject
        self.requiresPackage = requiresPackage
        self.destructive = destructive
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, detail, systemImage, command, requiresProject, requiresPackage, destructive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage) ?? "terminal"
        command = try c.decode([String].self, forKey: .command)
        requiresProject = try c.decodeIfPresent(Bool.self, forKey: .requiresProject) ?? false
        requiresPackage = try c.decodeIfPresent(Bool.self, forKey: .requiresPackage) ?? false
        destructive = try c.decodeIfPresent(Bool.self, forKey: .destructive) ?? false
    }
}

public struct StudioPluginManifest: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var author: String
    public var summary: String
    public var systemImage: String
    public var scopes: [PluginScope]
    public var actions: [PluginAction]

    public init(
        id: String,
        name: String,
        version: String = "1.0.0",
        author: String = "",
        summary: String = "",
        systemImage: String = "puzzlepiece.extension",
        scopes: [PluginScope] = [.global],
        actions: [PluginAction] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.summary = summary
        self.systemImage = systemImage
        self.scopes = scopes
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, author, summary, systemImage, scopes, actions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage) ?? "puzzlepiece.extension"
        scopes = try c.decodeIfPresent([PluginScope].self, forKey: .scopes) ?? [.global]
        actions = try c.decodeIfPresent([PluginAction].self, forKey: .actions) ?? []
    }
}

public enum PluginManifestValidator {
    public static func issues(in manifest: StudioPluginManifest) -> [String] {
        var issues: [String] = []
        if !validIdentifier(manifest.id) {
            issues.append("Plugin id must contain only lowercase letters, numbers, dots, dashes or underscores.")
        }
        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Plugin name is required.")
        }

        var actionIDs = Set<String>()
        for action in manifest.actions {
            if !validIdentifier(action.id) {
                issues.append("Action id '\(action.id)' is invalid.")
            }
            if !actionIDs.insert(action.id).inserted {
                issues.append("Action id '\(action.id)' is duplicated.")
            }
            if action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("Action '\(action.id)' needs a title.")
            }
            if action.command.isEmpty || action.command[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("Action '\(action.id)' needs a command.")
            }
            if action.requiresPackage && !action.requiresProject {
                issues.append("Action '\(action.id)' requires a package, so it must also require a project.")
            }
        }
        return issues
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value == value.lowercased() else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public struct PluginInvocationContext: Equatable, Sendable {
    public var projectPath: String?
    public var packagePath: String?
    public var theosPath: String?
    public var homePath: String
    public var pluginPath: String?

    public init(
        projectPath: String? = nil,
        packagePath: String? = nil,
        theosPath: String? = nil,
        homePath: String,
        pluginPath: String? = nil
    ) {
        self.projectPath = projectPath
        self.packagePath = packagePath
        self.theosPath = theosPath
        self.homePath = homePath
        self.pluginPath = pluginPath
    }
}

public enum PluginTokenExpander {
    public static func expand(_ value: String, context: PluginInvocationContext) -> String? {
        var result = value
        let replacements: [(String, String?)] = [
            ("{{project}}", context.projectPath),
            ("{{package}}", context.packagePath),
            ("{{theos}}", context.theosPath),
            ("{{home}}", context.homePath),
            ("{{plugin}}", context.pluginPath),
        ]
        for (token, replacement) in replacements where result.contains(token) {
            guard let replacement else { return nil }
            result = result.replacingOccurrences(of: token, with: replacement)
        }
        return result
    }

    public static func expand(_ command: [String], context: PluginInvocationContext) -> [String]? {
        var result: [String] = []
        for part in command {
            guard let expanded = expand(part, context: context) else { return nil }
            result.append(expanded)
        }
        return result
    }
}
