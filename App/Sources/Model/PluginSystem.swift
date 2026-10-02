import Foundation
import SwiftUI
import UniformTypeIdentifiers
import TheosStudioCore

struct InstalledPlugin: Identifiable, Equatable {
    enum Source: Equatable {
        case builtIn
        case external(root: String)

        var label: String {
            switch self {
            case .builtIn: return "Built in"
            case .external: return "External"
            }
        }

        var rootPath: String? {
            if case .external(let root) = self { return root }
            return nil
        }
    }

    var id: String { manifest.id }
    var manifest: StudioPluginManifest
    var source: Source
    var isEnabled: Bool
}

@MainActor
final class PluginManager: ObservableObject {
    @Published private(set) var plugins: [InstalledPlugin] = []
    @Published private(set) var loadIssues: [String] = []

    private static let disabledKey = "com.r0gueee.theosstudio.disabled-plugins"

    var enabledPlugins: [InstalledPlugin] {
        plugins.filter(\.isEnabled)
    }

    var projectPlugins: [InstalledPlugin] {
        enabledPlugins.filter { $0.manifest.scopes.contains(.project) }
    }

    var contributedSnippets: [Snippet] {
        enabledPlugins.flatMap { plugin in
            plugin.manifest.snippets.map { $0.snippet(pluginID: plugin.id) }
        }
    }

    func reload() {
        try? FS.createDirectory(Paths.defaultPluginsDirectory)
        let disabled = Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? [])
        var loaded: [InstalledPlugin] = BuiltInPlugins.all.map {
            InstalledPlugin(manifest: $0, source: .builtIn, isEnabled: !disabled.contains($0.id))
        }
        var seen = Set(loaded.map(\.id))
        var issues: [String] = []

        for path in manifestPaths() {
            guard let text = FS.read(path), let data = text.data(using: .utf8) else {
                issues.append("\((path as NSString).lastPathComponent): could not be read.")
                continue
            }
            do {
                let manifest = try JSONDecoder().decode(StudioPluginManifest.self, from: data)
                let validation = PluginManifestValidator.issues(in: manifest)
                if !validation.isEmpty {
                    issues.append("\(manifest.name): \(validation.joined(separator: " "))")
                    continue
                }
                guard seen.insert(manifest.id).inserted else {
                    issues.append("\(manifest.name): duplicate plugin id '\(manifest.id)'.")
                    continue
                }
                let root = (path as NSString).deletingLastPathComponent
                loaded.append(InstalledPlugin(
                    manifest: manifest,
                    source: .external(root: root),
                    isEnabled: !disabled.contains(manifest.id)
                ))
            } catch {
                issues.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }

        plugins = loaded.sorted {
            if $0.source == .builtIn && $1.source != .builtIn { return true }
            if $0.source != .builtIn && $1.source == .builtIn { return false }
            return $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending
        }
        loadIssues = issues
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[index].isEnabled = enabled
        let disabled = plugins.filter { !$0.isEnabled }.map(\.id)
        UserDefaults.standard.set(disabled, forKey: Self.disabledKey)
    }

    func importManifest(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(StudioPluginManifest.self, from: data)
        let issues = PluginManifestValidator.issues(in: manifest)
        guard issues.isEmpty else {
            throw PluginImportError.invalid(issues.joined(separator: "\n"))
        }

        try FS.createDirectory(Paths.defaultPluginsDirectory)
        let destination = Paths.defaultPluginsDirectory + "/" + manifest.id + ".json"
        try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        reload()
    }

    private func manifestPaths() -> [String] {
        var result: [String] = []
        for name in FS.list(Paths.defaultPluginsDirectory).sorted() {
            let path = Paths.defaultPluginsDirectory + "/" + name
            if FS.fileExists(path), name.lowercased().hasSuffix(".json") {
                result.append(path)
            } else if FS.directoryExists(path) {
                let manifest = path + "/plugin.json"
                if FS.fileExists(manifest) { result.append(manifest) }
            }
        }
        return result
    }
}

enum PluginImportError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return detail
        }
    }
}

enum BuiltInPlugins {
    static let all: [StudioPluginManifest] = [
        StudioPluginManifest(
            id: "builtin.git-tools",
            name: "Git Tools",
            version: "1.0.0",
            author: "TheosStudio",
            summary: "Quick repository status and diff summaries for the selected project.",
            systemImage: "arrow.triangle.branch",
            scopes: [.project],
            actions: [
                PluginAction(
                    id: "git-status",
                    title: "Repository status",
                    detail: "Branch plus changed and untracked files.",
                    systemImage: "list.bullet.rectangle",
                    command: ["git", "-C", "{{project}}", "status", "--short", "--branch"],
                    requiresProject: true
                ),
                PluginAction(
                    id: "git-diff-stat",
                    title: "Diff statistics",
                    detail: "A compact summary of current uncommitted changes.",
                    systemImage: "chart.bar.doc.horizontal",
                    command: ["git", "-C", "{{project}}", "diff", "--stat"],
                    requiresProject: true
                ),
                PluginAction(
                    id: "git-recent",
                    title: "Recent commits",
                    detail: "The ten most recent commits in this project.",
                    systemImage: "clock.arrow.circlepath",
                    command: ["git", "-C", "{{project}}", "log", "-10", "--oneline", "--decorate"],
                    requiresProject: true
                ),
            ]
        ),
        StudioPluginManifest(
            id: "builtin.package-tools",
            name: "Package Tools",
            version: "1.0.0",
            author: "TheosStudio",
            summary: "Inspect the newest built .deb without installing it.",
            systemImage: "shippingbox",
            scopes: [.project],
            actions: [
                PluginAction(
                    id: "package-info",
                    title: "Debian package metadata",
                    detail: "Control fields, scripts and package metadata from dpkg-deb.",
                    systemImage: "info.circle",
                    command: ["dpkg-deb", "--info", "{{package}}"],
                    requiresProject: true,
                    requiresPackage: true
                ),
                PluginAction(
                    id: "package-contents",
                    title: "Package file listing",
                    detail: "Every path that the newest package would install.",
                    systemImage: "list.bullet.indent",
                    command: ["dpkg-deb", "--contents", "{{package}}"],
                    requiresProject: true,
                    requiresPackage: true
                ),
                PluginAction(
                    id: "package-fields",
                    title: "Key package fields",
                    detail: "Identifier, version, architecture and dependencies from the built package.",
                    systemImage: "list.bullet.rectangle.portrait",
                    command: ["dpkg-deb", "--field", "{{package}}", "Package", "Version", "Architecture", "Depends"],
                    requiresProject: true,
                    requiresPackage: true
                ),
            ]
        ),
        StudioPluginManifest(
            id: "builtin.device-tools",
            name: "Device Utilities",
            version: "1.0.0",
            author: "TheosStudio",
            summary: "Small diagnostics useful while developing directly on a jailbroken device.",
            systemImage: "iphone",
            scopes: [.global],
            actions: [
                PluginAction(
                    id: "kernel-info",
                    title: "Kernel and architecture",
                    detail: "Runs uname -a using the jailbreak tool path.",
                    systemImage: "cpu",
                    command: ["uname", "-a"]
                ),
                PluginAction(
                    id: "disk-space",
                    title: "Disk space",
                    detail: "Shows mounted filesystems and available space.",
                    systemImage: "internaldrive",
                    command: ["df", "-h"]
                ),
            ]
        ),
        StudioPluginManifest(
            id: "builtin.debug-snippets",
            name: "Debug Snippets",
            version: "1.0.0",
            author: "TheosStudio",
            summary: "Reusable runtime guards and logging helpers for tweak debugging.",
            systemImage: "ladybug",
            scopes: [.project],
            snippets: [
                PluginSnippet(
                    id: "runtime-class-guard",
                    title: "Runtime class and selector guard",
                    summary: "Confirm a private class and selector exist before calling them.",
                    language: .code,
                    suggestedFileName: "RuntimeChecks.x",
                    body: """
                    Class cls = NSClassFromString(@"SBIconView");
                    SEL selector = NSSelectorFromString(@"setHighlighted:");
                    if (cls && [cls instancesRespondToSelector:selector]) {
                        NSLog(@"[MyTweak] SBIconView has setHighlighted:");
                    } else {
                        NSLog(@"[MyTweak] expected private API is unavailable on this OS");
                    }
                    """
                ),
                PluginSnippet(
                    id: "darwin-notify",
                    title: "Darwin notification observer",
                    summary: "Listen for a cross-process notification without polling.",
                    language: .code,
                    suggestedFileName: "Notifications.x",
                    body: """
                    static void mytweak_notification(
                        CFNotificationCenterRef center,
                        void *observer,
                        CFNotificationName name,
                        const void *object,
                        CFDictionaryRef userInfo
                    ) {
                        NSLog(@"[MyTweak] notification received");
                    }

                    %ctor {
                        CFNotificationCenterAddObserver(
                            CFNotificationCenterGetDarwinNotifyCenter(),
                            NULL,
                            mytweak_notification,
                            CFSTR("com.example.mytweak/Reload"),
                            NULL,
                            CFNotificationSuspensionBehaviorDeliverImmediately
                        );
                    }
                    """
                ),
            ]
        ),
    ]
}

@MainActor
final class PluginActionRunner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case finished(Int32)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [String] = []
    private var process: ShellProcess?

    func run(plugin: InstalledPlugin, action: PluginAction, project: Project?, store: StudioStore) {
        guard phase != .running else { return }
        lines = []
        let context = PluginInvocationContext(
            projectPath: project?.path,
            packagePath: project?.builtPackage,
            theosPath: store.toolchain?.theosRoot,
            homePath: NSHomeDirectory(),
            pluginPath: plugin.source.rootPath
        )
        guard let command = PluginTokenExpander.expand(action.command, context: context), !command.isEmpty else {
                phase = .failed("This action needs project, package, Theos or plugin context that is not available.")
                return
            }

            let requested = command[0]
            let executable: String?
            if requested.hasPrefix("./"), let root = plugin.source.rootPath {
                executable = root + "/" + String(requested.dropFirst(2))
            } else if requested.hasPrefix("/") {
                executable = requested
            } else {
                executable = store.toolPaths(for: [requested])[requested]
            }

            guard let executable, FS.fileExists(executable) else {
                phase = .failed("The plugin needs '\(requested)', but TheosStudio could not find that executable.")
                return
            }

            let args = Array(command.dropFirst())
            let child = ShellProcess(executable: executable, arguments: args, environment: store.commandEnvironment())
            process = child
            lines.append("$ " + child.commandLine)
            phase = .running
            do {
                try child.run(onLine: { [weak self] line in
                    self?.lines.append(line)
                }, onExit: { [weak self] outcome in
                    self?.phase = .finished(outcome.status)
                    self?.process = nil
                })
            } catch {
                phase = .failed(error.localizedDescription)
                process = nil
            }
    }

    func cancel() {
        process?.terminate()
    }
}

@MainActor
struct PluginCenterView: View {
    @ObservedObject var store: StudioStore
    @EnvironmentObject private var manager: PluginManager
    @State private var selectedProjectPath: String?
    @State private var importing = false
    @State private var importError: String?
    @State private var pendingAction: PluginRunRequest?

    var body: some View {
        NavigationView {
            List {
                Section {
                    StudioHero(
                        eyebrow: "Extensions",
                        title: "Plugin Center",
                        subtitle: "Add project actions, snippets, diagnostics, and workflow integrations without expanding the core app.",
                        systemImage: "puzzlepiece.extension.fill",
                        tint: .purple
                    ) {
                        HStack(spacing: 7) {
                            StudioPill(text: "\(manager.plugins.count) installed", systemImage: "square.stack.3d.up.fill", tint: .purple)
                            StudioPill(text: "\(manager.plugins.filter { $0.isEnabled }.count) enabled", systemImage: "checkmark.circle.fill", tint: .green)
                            if !manager.loadIssues.isEmpty {
                                StudioPill(text: "\(manager.loadIssues.count) issue\(manager.loadIssues.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                if !store.projects.isEmpty {
                    Section {
                        Picker("Project context", selection: Binding(
                            get: { selectedProjectPath ?? store.projects.first?.path },
                            set: { selectedProjectPath = $0 }
                        )) {
                            ForEach(store.projects) { project in
                                Text(project.name).tag(Optional(project.path))
                            }
                        }
                    } footer: {
                        Text("Project plugins receive this project path and its newest built package.")
                    }
                }

                Section {
                    ForEach(manager.plugins) { plugin in
                        NavigationLink(destination: PluginDetailView(
                            store: store,
                            plugin: plugin,
                            project: projectForContext,
                            onRun: { action in pendingAction = PluginRunRequest(plugin: plugin, action: action) }
                        )) {
                            HStack(spacing: 12) {
                                Image(systemName: plugin.manifest.systemImage)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plugin.manifest.name)
                                    Text(plugin.manifest.summary)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                    let actionCount = plugin.manifest.actions.count
                                    let snippetCount = plugin.manifest.snippets.count
                                    if actionCount > 0 || snippetCount > 0 {
                                        Text([
                                            actionCount > 0 ? "\(actionCount) action\(actionCount == 1 ? "" : "s")" : nil,
                                            snippetCount > 0 ? "\(snippetCount) snippet\(snippetCount == 1 ? "" : "s")" : nil,
                                        ].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if !plugin.isEnabled {
                                    Text("Off").font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Installed plugins")
                }

                Section {
                    Button {
                        importing = true
                    } label: {
                        Label("Import plugin manifest", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        manager.reload()
                    } label: {
                        Label("Rescan plugins folder", systemImage: "arrow.clockwise")
                    }
                    DetailRow(
                        label: "Folder",
                        value: Paths.defaultPluginsDirectory.removingPrefix(NSHomeDirectory()),
                        monospaced: true
                    )
                } header: {
                    Text("External plugins")
                } footer: {
                    Text("Drop JSON manifests here with Filza, or import one from Files. Commands are argument arrays, not shell strings. Project metadata and filesystem paths are available as tokens.")
                }

                if !manager.loadIssues.isEmpty {
                    Section {
                        ForEach(manager.loadIssues, id: \.self) { issue in
                            Text(issue).font(.footnote).foregroundColor(.orange)
                        }
                    } header: {
                        Text("Plugin problems")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Plugins")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { manager.reload() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            manager.reload()
            if selectedProjectPath == nil { selectedProjectPath = store.projects.first?.path }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                try manager.importManifest(from: url)
            } catch {
                importError = error.localizedDescription
            }
        }
        .alert("Could not import plugin", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .sheet(item: $pendingAction) { request in
            PluginConsoleView(store: store, plugin: request.plugin, action: request.action, project: projectForContext)
        }
    }

    private var projectForContext: Project? {
        let path = selectedProjectPath ?? store.projects.first?.path
        return path.flatMap(store.project(at:))
    }
}

private struct PluginRunRequest: Identifiable {
    let id = UUID()
    let plugin: InstalledPlugin
    let action: PluginAction
}

@MainActor
struct PluginDetailView: View {
    @ObservedObject var store: StudioStore
    @EnvironmentObject private var manager: PluginManager
    let plugin: InstalledPlugin
    let project: Project?
    let onRun: (PluginAction) -> Void

    private var livePlugin: InstalledPlugin {
        manager.plugins.first(where: { $0.id == plugin.id }) ?? plugin
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: Binding(
                    get: { livePlugin.isEnabled },
                    set: { manager.setEnabled($0, for: plugin.id) }
                ))
                DetailRow(label: "Version", value: plugin.manifest.version)
                DetailRow(label: "Source", value: plugin.source.label)
                if !plugin.manifest.author.isEmpty {
                    DetailRow(label: "Author", value: plugin.manifest.author)
                }
            } header: {
                Text(plugin.manifest.name)
            } footer: {
                Text(plugin.manifest.summary)
            }

            if !plugin.manifest.actions.isEmpty {
                Section {
                    ForEach(plugin.manifest.actions) { action in
                        Button {
                            onRun(action)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(action.title, systemImage: action.systemImage)
                                if !action.detail.isEmpty {
                                    Text(action.detail).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        .disabled(!livePlugin.isEnabled || unavailable(action))
                    }
                } header: {
                    Text("Actions")
                } footer: {
                    if !livePlugin.isEnabled {
                        Text("Enable this plugin to run its actions.")
                    } else if project == nil && plugin.manifest.scopes.contains(.project) {
                        Text("Choose a project context in the Plugin Center.")
                    }
                }
    
            }

            if !plugin.manifest.snippets.isEmpty {
                Section {
                    ForEach(plugin.manifest.snippets) { snippet in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.title)
                            Text(snippet.summary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(snippet.suggestedFileName)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Editor snippets")
                } footer: {
                    Text(livePlugin.isEnabled
                         ? "These are available from the Snippets menu in the code editor."
                         : "Enable this plugin to add its snippets to the editor.")
                }
            }
        }
        .navigationTitle(plugin.manifest.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func unavailable(_ action: PluginAction) -> Bool {
        if action.requiresProject && project == nil { return true }
        if action.requiresPackage && project?.builtPackage == nil { return true }
        return false
    }
}

@MainActor
struct PluginConsoleView: View {
    @ObservedObject var store: StudioStore
    let plugin: InstalledPlugin
    let action: PluginAction
    let project: Project?
    @StateObject private var runner = PluginActionRunner()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title).font(.headline)
                        Text(plugin.manifest.name).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    phaseLabel
                }
                .padding()

                Divider()
                if action.destructive, runner.phase == .idle {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("This action can modify or delete data.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.orange)
                        Text("Review the command, then tap Run. Destructive plugin actions never start automatically.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    Divider()
                }
                ConsoleText(lines: runner.lines)
            }
            .navigationTitle("Plugin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if case .running = runner.phase {
                        Button("Stop", role: .destructive) { runner.cancel() }
                    } else {
                        Button("Run") { runner.run(plugin: plugin, action: action, project: project, store: store) }
                    }
                }
            }
            .onAppear {
                if !action.destructive {
                    runner.run(plugin: plugin, action: action, project: project, store: store)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch runner.phase {
        case .idle:
            Text("idle").foregroundColor(.secondary)
        case .running:
            ProgressView()
        case .finished(let status):
            StatusChip(text: status == 0 ? "exit 0" : "exit \(status)", color: status == 0 ? .green : .orange)
        case .failed(let message):
            StatusChip(text: message, color: .red)
        }
    }
}
