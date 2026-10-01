import Foundation

/// Something the assistant asked to do, after the model's JSON has been parsed
/// and checked. Everything that touches the device is one of these, which is what
/// makes "may this run without asking?" a question with a single answer.
public enum AgentAction: Equatable, Sendable {
    case listFiles
    case readFile(path: String)
    case writeFile(path: String, contents: String)
    case replaceInFile(path: String, find: String, replace: String)
    /// `value == nil` removes the field.
    case updateControl(key: String, value: String?)
    case build(clean: Bool, final: Bool)
    case install
    case finish(summary: String)
    /// Anything unrecognised, with the reason to hand back to the model. A tool
    /// call the app cannot parse is a prompt for a retry, not a crash.
    case unknown(name: String, reason: String)

    public var toolName: String {
        switch self {
        case .listFiles: return "list_files"
        case .readFile: return "read_file"
        case .writeFile: return "write_file"
        case .replaceInFile: return "replace_in_file"
        case .updateControl: return "update_control"
        case .build: return "build"
        case .install: return "install"
        case .finish: return "finish"
        case .unknown(let name, _): return name
        }
    }

    /// One line for the transcript.
    public var summary: String {
        switch self {
        case .listFiles:
            return "List the project's files"
        case .readFile(let path):
            return "Read \(path)"
        case .writeFile(let path, let contents):
            return "Write \(path) (\(contents.utf8.count) bytes)"
        case .replaceInFile(let path, _, _):
            return "Edit \(path)"
        case .updateControl(let key, let value):
            return value == nil ? "Remove \(key) from control" : "Set \(key) in control"
        case .build(let clean, let final):
            return "Build\(clean ? " (clean first)" : "")\(final ? " (final package)" : "")"
        case .install:
            return "Install the built package"
        case .finish(let summary):
            return "Finish: \(summary)"
        case .unknown(let name, let reason):
            return "Unknown tool \(name): \(reason)"
        }
    }
}

public enum AgentActionParser {

    /// Turns a tool call into an action, or into `.unknown` carrying the reason —
    /// which is sent back to the model as the tool's result, so a model that gets
    /// an argument name wrong can correct itself instead of failing the turn.
    public static func parse(_ call: AgentToolCall) -> AgentAction {
        guard let data = call.arguments.data(using: .utf8) else {
            return .unknown(name: call.name, reason: "arguments were not UTF-8")
        }
        let arguments: [String: JSONValue]
        do {
            arguments = try JSONDecoder().decode([String: JSONValue].self, from: data)
        } catch {
            // Models sometimes emit an empty string or a truncated object.
            return .unknown(name: call.name, reason: "arguments were not a JSON object: \(call.arguments.prefix(120))")
        }

        func string(_ key: String) -> String? { arguments[key]?.stringValue }
        func flag(_ key: String, default fallback: Bool) -> Bool { arguments[key]?.boolValue ?? fallback }

        switch call.name {
        case "list_files":
            return .listFiles

        case "read_file":
            guard let path = string("path"), !path.isEmpty else {
                return .unknown(name: call.name, reason: "read_file needs a 'path'")
            }
            return .readFile(path: path)

        case "write_file":
            guard let path = string("path"), !path.isEmpty else {
                return .unknown(name: call.name, reason: "write_file needs a 'path'")
            }
            guard let contents = string("contents") else {
                return .unknown(name: call.name, reason: "write_file needs 'contents' (the whole file)")
            }
            return .writeFile(path: path, contents: contents)

        case "replace_in_file":
            guard let path = string("path"), !path.isEmpty else {
                return .unknown(name: call.name, reason: "replace_in_file needs a 'path'")
            }
            guard let find = string("find"), !find.isEmpty else {
                return .unknown(name: call.name, reason: "replace_in_file needs 'find' — the exact text to replace")
            }
            guard let replace = string("replace") else {
                return .unknown(name: call.name, reason: "replace_in_file needs 'replace' (use an empty string to delete)")
            }
            return .replaceInFile(path: path, find: find, replace: replace)

        case "update_control":
            guard let key = string("key"), !key.isEmpty else {
                return .unknown(name: call.name, reason: "update_control needs a 'key'")
            }
            // A missing value means "remove the field", which is how a package
            // drops a dependency it no longer has.
            return .updateControl(key: key, value: string("value"))

        case "build":
            return .build(clean: flag("clean", default: false), final: flag("final", default: true))

        case "install":
            return .install

        case "finish":
            guard let summary = string("summary") else {
                return .unknown(name: call.name, reason: "finish needs a 'summary' for the user")
            }
            return .finish(summary: summary)

        default:
            return .unknown(name: call.name, reason: "there is no tool with that name")
        }
    }

    public static func parse(_ calls: [AgentToolCall]) -> [AgentAction] {
        calls.map(parse)
    }
}

/// The tools offered to the model.
///
/// Deliberately small and file-shaped: a tweak is five text files and a build, so
/// the useful verbs are read, edit, build and install. Every one of them is
/// described in terms of what it does to the project, because that description is
/// what the model has to plan with.
public enum AgentToolCatalog {

    public static let all: [AgentTool] = [
        AgentTool(
            name: "list_files",
            description: "List every file in the project, with sizes. Call this first when you are unsure what exists.",
            parameters: .schema(properties: [:], required: [])
        ),
        AgentTool(
            name: "read_file",
            description: "Read a project file. Paths are relative to the project root, e.g. 'Tweak.x' or 'prefs/Makefile'.",
            parameters: .schema(
                properties: ["path": .property("string", "Path relative to the project root.")],
                required: ["path"]
            )
        ),
        AgentTool(
            name: "write_file",
            description: "Replace a whole file with new contents. Use it for new files and rewrites; prefer replace_in_file for a small change, because the user reviews the diff before anything is written.",
            parameters: .schema(
                properties: [
                    "path": .property("string", "Path relative to the project root."),
                    "contents": .property("string", "The complete new contents of the file."),
                ],
                required: ["path", "contents"]
            )
        ),
        AgentTool(
            name: "replace_in_file",
            description: "Replace an exact piece of text in a file. 'find' must match the file byte for byte, once. This is the tool to use for editing an existing file.",
            parameters: .schema(
                properties: [
                    "path": .property("string", "Path relative to the project root."),
                    "find": .property("string", "The exact text to replace, including indentation."),
                    "replace": .property("string", "The replacement. An empty string deletes the text."),
                ],
                required: ["path", "find", "replace"]
            )
        ),
        AgentTool(
            name: "update_control",
            description: "Set or remove one field of the Debian control file, e.g. Depends, Version or Description. Use it instead of rewriting control by hand. Omitting 'value' removes the field.",
            parameters: .schema(
                properties: [
                    "key": .property("string", "Field name, e.g. 'Depends'."),
                    "value": .property("string", "New value. Omit to remove the field."),
                ],
                required: ["key"]
            )
        ),
        AgentTool(
            name: "build",
            description: "Run make package for this project and get the compiler output back, including errors and warnings with file and line. Call it after every change worth verifying.",
            parameters: .schema(
                properties: [
                    "clean": .property("boolean", "Run make clean first. Use it when an edit seems to have had no effect."),
                    "final": .property("boolean", "Build a release package (FINALPACKAGE=1). Defaults to true."),
                ],
                required: []
            )
        ),
        AgentTool(
            name: "install",
            description: "Install the package the last build produced with dpkg, then respring. Only call it when the user asked for the tweak to be installed.",
            parameters: .schema(properties: [:], required: [])
        ),
        AgentTool(
            name: "finish",
            description: "End your turn. Say what you changed, what you checked, and what the user should do next — including anything you could not verify.",
            parameters: .schema(
                properties: ["summary": .property("string", "The summary to show the user.")],
                required: ["summary"]
            )
        ),
    ]

    public static let names = Set(all.map(\.name))
}
