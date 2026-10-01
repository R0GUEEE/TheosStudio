import SwiftUI
import TheosStudioCore

/// The assistant, scoped to one project.
///
/// The transcript is the point: every tool call is a line, every change is shown
/// as a diff, and nothing that writes to the project happens until the user taps
/// Approve. That is what makes an agent that edits code on a phone usable.
@MainActor
struct AssistantView: View {

    @ObservedObject var store: StudioStore
    @EnvironmentObject private var plugins: PluginManager
    @StateObject private var session = AgentSession()
    @StateObject private var runner = BuildRunner()
    @StateObject private var installer = PackageInstaller()
    @StateObject private var headers = HeaderIndexer()
    @State private var draft = ""
    @State private var isShowingSettings = false

    private var project: Project? {
        guard let path = store.assistantProjectPath else { return store.projects.first }
        return store.projects.first { $0.path == path } ?? store.projects.first
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if store.projects.isEmpty {
                    emptyState
                } else if !session.isConfigured {
                    header
                    Divider()
                    setupCard
                } else {
                    header
                    Divider()
                    transcript
                    Divider()
                    composer
                }
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        ForEach(store.projects) { candidate in
                            Button {
                                store.assistantProjectPath = candidate.path
                                session.reset()
                            } label: {
                                Label(candidate.name, systemImage: candidate.path == project?.path ? "checkmark" : "hammer")
                            }
                        }
                    } label: {
                        Label(project?.name ?? "No project", systemImage: "folder")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            isShowingSettings = true
                        } label: {
                            Label("Assistant settings", systemImage: "gearshape")
                        }
                        if let project {
                            if hasBriefing(project) {
                                Button {
                                    openBriefing(project)
                                } label: {
                                    Label("Edit the project briefing", systemImage: "doc.text")
                                }
                            } else {
                                Button {
                                    createBriefing(project)
                                } label: {
                                    Label("Write a project briefing", systemImage: "doc.badge.plus")
                                }
                            }
                        }
                        Button {
                            session.reset()
                        } label: {
                            Label("Clear conversation", systemImage: "trash")
                        }
                        if session.phase.isBusy {
                            Button(role: .destructive) {
                                session.stop()
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                            }
                        }
                    } label: {
                        Label("Assistant options", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                NavigationView {
                    AgentSettingsView(store: store) { 
                        isShowingSettings = false
                        configureSession()
                    }
                }
                .navigationViewStyle(.stack)
            }
            .onAppear {
                configureSession()
                if store.assistantProjectPath == nil { store.assistantProjectPath = store.projects.first?.path }
                installer.refreshInstalled(store: store)
                plugins.reload()
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Pieces

    /// Shown instead of the transcript until there is a model to talk to. The
    /// steps are the setup screen's order, because that is the order that works.
    private var setupCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Set up a model", systemImage: "sparkles").font(.headline)
                Text("The assistant works with any OpenAI-compatible endpoint, with a key of your own. Three steps:")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    setupStep(1, "Pick a provider", "OpenAI, DeepSeek, OpenRouter, a local Ollama — or a custom endpoint.")
                    setupStep(2, "Paste an API key", "Kept in the keychain, sent only to that provider.")
                    setupStep(3, "Load the model list", "The provider's own list is fetched, so the model is picked, not typed.")
                }

                Button {
                    isShowingSettings = true
                } label: {
                    Label("Set up the assistant", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)

                Text("Until then, everything else in the app works: projects, the editor, building and installing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setupStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.2))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundColor(.secondary)
            Text("No projects yet").font(.headline)
            Text("The assistant works on one project at a time. Create or open a project first.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let project {
                    Text(project.name).font(.subheadline.weight(.medium))
                    StatusChip(text: project.displayScheme, color: .blue)
                }
                Spacer()
                if session.isConfigured {
                    StatusChip(text: store.agent.provider.displayName, color: .secondary)
                    StatusChip(text: store.agent.model, color: .green)
                } else {
                    Button("Set up the model") { isShowingSettings = true }
                        .font(.footnote)
                }
            }
            switch session.phase {
            case .thinking:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Working…").font(.caption).foregroundColor(.secondary)
                }
            case .awaitingApproval:
                Text("Waiting for your approval below.").font(.caption).foregroundColor(.orange)
            case .failed(let message):
                Text(message).font(.caption).foregroundColor(.red)
            case .idle:
                Text("Reads are free. Every edit, build and install stops here for approval.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.entries) { entry in
                        TranscriptRow(entry: entry).id(entry.id)
                    }
                    if let streaming = session.streamingText, !streaming.isEmpty {
                        Text(streaming)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .id("streaming")
                    }
                    if let approval = session.pendingApproval {
                        ApprovalCard(
                            approval: approval,
                            onApprove: { session.approve() },
                            onDeny: { session.deny() }
                        )
                        .id("approval")
                    }
                }
                .padding(12)
            }
            .background(Color(.systemBackground))
            .onChange(of: session.entries.count) { _ in
                guard let last = session.entries.last else { return }
                withAnimation(.linear(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: session.streamingText) { text in
                guard text != nil else { return }
                proxy.scrollTo("streaming", anchor: .bottom)
            }
            .onChange(of: session.pendingApproval?.id) { _ in
                guard session.pendingApproval != nil else { return }
                withAnimation(.linear(duration: 0.15)) { proxy.scrollTo("approval", anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                ForEach(Self.prompts, id: \.self) { prompt in
                    Button(prompt) { draft = prompt }
                }
            } label: {
                Image(systemName: "text.badge.plus").font(.title3)
            }

            TextField("Ask for a change, or what is wrong", text: $draft, onCommit: sendDraft)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.sentences)
                .disableAutocorrection(true)

            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || session.phase.isBusy || !session.isConfigured)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private static let prompts = [
        "Build the project and fix what fails.",
        "Review Tweak.x and tell me what could go wrong on this iOS version.",
        "Add a switch to the preference bundle that disables the tweak.",
        "Make the injection filter narrower and explain the change.",
        "Explain what this tweak does, in one paragraph.",
    ]

    // MARK: - Wiring

    // MARK: - The project's briefing

    /// A project can explain itself to the assistant, once, in a file that
    /// travels with the project and shows up in its file list.
    private func hasBriefing(_ project: Project) -> Bool {
        FS.fileExists(project.path + "/AGENT.md")
    }

    private func createBriefing(_ project: Project) {
        let template = """
        # Briefing for the assistant

        Read on every request. Keep it short: these are standing facts and rules,
        not a conversation.

        ## This project
        - What it does:
        - Which process it hooks:
        - iOS versions it has to support:

        ## Rules for you
        - Change as little as possible, and say what you could not verify.
        - Do not add a dependency without asking.
        - Keep the injection filter narrow.
        """
        do {
            try FS.write(template, to: project.path + "/AGENT.md")
            store.banner = BannerMessage(
                title: "Briefing created",
                body: "AGENT.md is in the project and is sent with every request. It is in the file list, so it can be edited like anything else."
            )
        } catch {
            store.banner = BannerMessage(title: "Could not write AGENT.md", body: error.localizedDescription)
        }
    }

    private func openBriefing(_ project: Project) {
        store.assistantProjectPath = project.path
        store.banner = BannerMessage(
            title: "AGENT.md",
            body: "Open it from the project's file list to edit it — it is sent with every request."
        )
    }

    private func configureSession() {
        session.configure(
            settings: store.agent,
            apiKey: AgentKeyStore.load(for: store.agent.providerID) ?? ""
        )
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let environment = environment() else { return }
        draft = ""
        session.send(text, environment: environment)
    }

    private func environment() -> AgentEnvironment? {
        guard let project else { return nil }
        let path = project.path
        return AgentEnvironment(
            projectPath: path,
            listFiles: { FS.projectEntries(at: path, depth: 5) },
            readFile: { FS.read(path + "/" + $0) },
            writeFile: { relative, contents in try FS.write(contents, to: path + "/" + relative) },
            loadControl: { ControlFile.parse(FS.read(path + "/control") ?? "") },
            saveControl: { control in try FS.write(control.serialized(), to: path + "/control") },
            build: { clean, final in await runBuild(project: project, clean: clean, final: final) },
            install: { await runInstall(project: project) },
            crashSummaries: { limit in
                CrashService.summaries(
                    store: store,
                    names: CrashService.interestingNames(for: project),
                    limit: limit
                )
            },
            gitStatus: { await gitStatusText(project: project) },
            gitDiff: { path in await gitDiffText(project: project, path: path) },
            searchHeaders: { query in
                await headers.searchOrIndex(query, roots: headerRoots)
            },
            workspaceStatus: { workspaceStatus(project: project) },
            projectHealth: { projectHealthText(project: project) },
            projectStats: { projectStatsText(project: project) },
            launchTargets: { launchTargetsText(project: project) },
            inspectPackage: { packageInspectionText(project: project) },
            installedPackages: { query in installedPackagesText(query: query) },
            plugins: { pluginsText(project: project) },
            runPlugin: { pluginID, actionID in
                await runPlugin(pluginID: pluginID, actionID: actionID, project: project)
            },
            restartTarget: { name in await restartTarget(name, project: project) },
            privilegesCanEscalate: store.privileges.canEscalate,
            toolchainSummary: toolchainSummary
        )
    }

    private func workspaceStatus(project: Project) -> String {
        var lines = [
            "Projects: \(store.projects.count)",
            "Selected: \(project.name) [\(project.displayScheme)]",
            "Privileges: \(store.privileges.summary)",
            "Enabled plugins: \(plugins.enabledPlugins.count)",
            "Installed packages indexed: \(installer.installed.count)",
        ]
        lines.append(contentsOf: store.projects.prefix(20).map { candidate in
            let marker = candidate.path == project.path ? "*" : "-"
            return "\(marker) \(candidate.name) · \(candidate.kind?.displayName ?? "unknown") · \(candidate.displayScheme) · \(candidate.version ?? "no version")"
        })
        if let report = store.toolchain {
            lines.append("Theos: \(report.theosRoot ?? "not found")")
            lines.append("SDKs: \(report.sdkDirectories.count)")
            let missing = report.missingRequired.map(\.tool.name)
            if !missing.isEmpty { lines.append("Missing required tools: " + missing.joined(separator: ", ")) }
        }
        return lines.joined(separator: "\n")
    }

    private func textFiles(project: Project) -> [ProjectFile] {
        FS.projectEntries(at: project.path, depth: 8)
            .filter { !$0.isDirectory && $0.isProbablyText && $0.size <= 1024 * 1024 }
            .compactMap { entry in
                FS.read(project.path + "/" + entry.relativePath).map {
                    ProjectFile(path: entry.relativePath, contents: $0)
                }
            }
    }

    private func projectHealthText(project: Project) -> String {
        let issues = ProjectHealth.inspect(files: textFiles(project: project))
        guard !issues.isEmpty else { return "No project-level health issues found." }
        return issues.map { issue in
            let path = issue.path.map { " [\($0)]" } ?? ""
            return "\(issue.severity.rawValue.uppercased())\(path): \(issue.message)"
        }.joined(separator: "\n")
    }

    private func projectStatsText(project: Project) -> String {
        let metrics = ProjectMetrics.calculate(files: textFiles(project: project))
        var lines = [
            "Text files: \(metrics.textFileCount)",
            "Lines: \(metrics.lineCount)",
            "Non-blank lines: \(metrics.nonBlankLineCount)",
            "Text bytes: \(metrics.bytes)",
        ]
        if !metrics.languages.isEmpty {
            lines.append("Languages: " + metrics.languages.keys.sorted().map { "\($0)=\(metrics.languages[$0] ?? 0)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private func currentLaunchTargets(project: Project) -> [LaunchTarget] {
        let makefile = FS.read(project.path + "/Makefile") ?? ""
        let filter = FS.read(project.path + "/" + project.name + ".plist")
        return LaunchTargets.targets(inMakefile: makefile, filterPlist: filter)
    }

    private func launchTargetsText(project: Project) -> String {
        let targets = currentLaunchTargets(project: project)
        guard !targets.isEmpty else { return "No restart targets were inferred from INSTALL_TARGET_PROCESSES or the injection filter." }
        return targets.map { "\($0.name): \($0.detail)" }.joined(separator: "\n")
    }

    private func installedPackagesText(query: String?) -> String {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let matches = installer.installed.filter {
            trimmed.isEmpty || $0.identifier.lowercased().contains(trimmed) || $0.name.lowercased().contains(trimmed)
        }
        guard !matches.isEmpty else {
            return installer.installed.isEmpty
                ? "No installed-package index is available yet. Refresh Installed Packages and try again."
                : "No installed package matched \(query ?? "")."
        }
        return matches.prefix(100).map { "\($0.identifier) \($0.version)" }.joined(separator: "\n")
    }

    private func pluginsText(project: Project) -> String {
        let enabled = plugins.enabledPlugins
        guard !enabled.isEmpty else { return "No plugins are enabled." }
        return enabled.map { plugin in
            let actions = plugin.manifest.actions.filter { action in
                !action.requiresProject || (!action.requiresPackage || project.builtPackage != nil)
            }
            let actionText = actions.map { "\($0.id): \($0.title)" }.joined(separator: ", ")
            return "\(plugin.id) · \(plugin.manifest.name) · \(plugin.source.label)\n  \(actionText.isEmpty ? "no currently available actions" : actionText)"
        }.joined(separator: "\n")
    }

    private func packageInspectionText(project: Project) -> String {
        guard let artifact = ArtifactLocator.newestPackage(
            in: project.path,
            listDirectory: FS.list,
            modificationDate: FS.modificationDate
        ) else { return "No built .deb exists for this project." }
        guard let dpkgDeb = store.toolPaths(for: ["dpkg-deb"])["dpkg-deb"] else {
            return "dpkg-deb is not installed, so the package cannot be inspected."
        }
        let info = runSyncTool(dpkgDeb, ["--info", artifact])
        let contents = runSyncTool(dpkgDeb, ["--contents", artifact])
        let entries = DebListing.parse(contents)
        var lines = ["Package: \((artifact as NSString).lastPathComponent)"]
        lines.append(contentsOf: DebListing.summary(entries: entries, control: ControlFile.parse(FS.read(project.path + "/control") ?? ""), scheme: project.scheme).map { "\($0.label): \($0.value)" })
        let paths = DebListing.files(entries).prefix(40).map(\.installedPath)
        if !paths.isEmpty { lines.append("Files:\n" + paths.joined(separator: "\n")) }
        if !info.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("dpkg-deb info:\n" + String(info.prefix(4000)))
        }
        return lines.joined(separator: "\n")
    }

    private func runSyncTool(_ executable: String, _ arguments: [String]) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        let process = ShellProcess(executable: executable, arguments: arguments, environment: store.commandEnvironment())
        do {
            try process.run(onLine: { line in result += line + "\n" }, onExit: { outcome in
                if result.isEmpty { result = outcome.output }
                semaphore.signal()
            })
            _ = semaphore.wait(timeout: .now() + 8)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
        return result
    }

    private func runPlugin(pluginID: String, actionID: String, project: Project) async -> String {
        guard let plugin = plugins.enabledPlugins.first(where: { $0.id == pluginID }) else {
            return "Error: plugin '\(pluginID)' is not enabled."
        }
        guard let action = plugin.manifest.actions.first(where: { $0.id == actionID }) else {
            return "Error: plugin '\(pluginID)' has no action '\(actionID)'."
        }
        if action.requiresPackage && project.builtPackage == nil {
            return "Error: this plugin action requires a built package."
        }
        let context = PluginInvocationContext(
            projectPath: project.path,
            projectName: project.name,
            packageIdentifier: project.packageIdentifier,
            packagingScheme: project.displayScheme,
            packagePath: project.builtPackage,
            theosPath: store.toolchain?.theosRoot,
            homePath: NSHomeDirectory(),
            pluginPath: plugin.source.rootPath
        )
        guard let command = PluginTokenExpander.expand(action.command, context: context), let requested = command.first else {
            return "Error: the plugin needs context that is not available."
        }
        let executable: String?
        if requested.hasPrefix("./"), let root = plugin.source.rootPath {
            executable = root + "/" + String(requested.dropFirst(2))
        } else if requested.hasPrefix("/") {
            executable = requested
        } else {
            executable = store.toolPaths(for: [requested])[requested]
        }
        guard let executable, FS.fileExists(executable) else {
            return "Error: executable '\(requested)' was not found."
        }
        return await runTool(executable, Array(command.dropFirst()))
    }

    private func runTool(_ executable: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            var output = ""
            let process = ShellProcess(executable: executable, arguments: arguments, environment: store.commandEnvironment())
            do {
                try process.run(onLine: { line in output += line + "\n" }, onExit: { outcome in
                    if output.isEmpty { output = outcome.output }
                    continuation.resume(returning: "Exit \(outcome.status)\n" + String(output.prefix(12000)))
                })
            } catch {
                continuation.resume(returning: "Error: \(error.localizedDescription)")
            }
        }
    }

    private func restartTarget(_ name: String, project: Project) async -> String {
        let allowed = currentLaunchTargets(project: project).map(\.name)
        guard allowed.contains(name) else {
            return "Error: '\(name)' is not one of this project's launch targets: \(allowed.joined(separator: ", "))."
        }
        return await withCheckedContinuation { continuation in
            var resumed = false
            installer.onResult = { ok, message in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: ok ? message : "Error: " + message)
            }
            installer.restart(name, store: store)
        }
    }

    /// The same sources the Find a hook screen uses: every SDK Theos has, plus
    /// whatever header folders the user pointed at.
    private var headerRoots: [String] {
        HeaderIndexer.sdkRoots(theosRoot: store.toolchain?.theosRoot)
            + store.settings.headerSearchFolders.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var toolchainSummary: String {
        guard let report = store.toolchain else { return "Not scanned yet." }
        var lines = [
            "Theos: \(report.theosRoot ?? "not found")",
            "SDKs: \(report.sdkDirectories.isEmpty ? "none" : report.sdkDirectories.joined(separator: ", "))",
            "Privileges: \(store.privileges.summary)",
        ]
        let missing = report.missingRequired.map(\.tool.name)
        if !missing.isEmpty {
            lines.append("Missing tools: \(missing.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    /// Builds through the same runner the project screen uses, so the console
    /// shows the same output — and waits for it, because the assistant needs the
    /// diagnostics as a value.
    private func runBuild(project: Project, clean: Bool, final: Bool) async -> BuildRunner.Outcome {
        await withCheckedContinuation { continuation in
            var resumed = false
            runner.onOutcome = { outcome in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: outcome)
            }
            runner.build(project: project, store: store, cleanOnly: false, cleanOverride: clean, finalOverride: final)
        }
    }

    /// What the assistant is told about the working tree: the branch, what
    /// changed, and the diffstat. The diff itself is a separate tool, because it
    /// is long.
    private func gitStatusText(project: Project) async -> String {
        guard GitService.isRepository(project: project.path) else {
            return "This project is not a git repository. It can be initialised from the project's Source control screen."
        }
        guard GitService.toolPath(store: store) != nil else {
            return "git is not installed on this device."
        }
        let branch = await GitService.branch(project: project.path, store: store) ?? "unknown"
        let files = await GitService.status(project: project.path, store: store)
        var lines = ["Branch: \(branch)", GitPorcelain.summary(files)]
        for file in files.prefix(40) {
            lines.append("  \(file.path) — \(file.label)")
        }
        let stat = await GitService.diffStat(project: project.path, store: store)
        if !stat.isEmpty { lines.append(stat) }
        return lines.joined(separator: "\n")
    }

    private func gitDiffText(project: Project, path: String?) async -> String {
        guard GitService.isRepository(project: project.path) else {
            return "This project is not a git repository."
        }
        let diff = await GitService.diff(project: project.path, path: path, store: store)
        guard !diff.isEmpty else {
            return path.map { "No unstaged changes in \($0)." } ?? "No unstaged changes."
        }
        // Long diffs are truncated rather than dropped: the beginning is where
        // the file names are.
        return String(diff.prefix(8000))
    }

    private func runInstall(project: Project) async -> (Bool, String) {
        guard let artifact = ArtifactLocator.newestPackage(
            in: project.path,
            listDirectory: FS.list,
            modificationDate: FS.modificationDate
        ) else {
            return (false, "No package has been built yet. Build first.")
        }
        return await withCheckedContinuation { continuation in
            var resumed = false
            installer.onResult = { ok, message in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: (ok, message))
            }
            installer.install(debPath: artifact, store: store)
        }
    }
}

private struct TranscriptRow: View {
    let entry: AgentSession.Entry

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        case .assistant:
            Text(entry.text)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver").font(.caption2).foregroundColor(.blue)
                Text(entry.title ?? entry.text).font(.caption).foregroundColor(.secondary)
            }
        case .result:
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title ?? "Result").font(.caption).foregroundColor(.secondary)
                Text(entry.text)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(12)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        case .approval:
            VStack(alignment: .leading, spacing: 4) {
                Label(entry.title ?? "Approved", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundColor(.green)
                if !entry.text.isEmpty { DiffText(entry.text) }
            }
        case .note:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").font(.caption2).foregroundColor(.orange)
                Text(entry.text).font(.caption)
            }
        case .error:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill").font(.caption2).foregroundColor(.red)
                Text(entry.text).font(.caption)
            }
        }
    }
}

private struct ApprovalCard: View {
    let approval: AgentSession.Approval
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval needed", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
            Text(approval.reason).font(.footnote)
            if let diff = approval.diff {
                DiffText(diff).frame(maxHeight: 260)
            }
            HStack {
                Button("Deny", role: .destructive, action: onDeny)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// A diff, coloured the way a diff is read.
private struct DiffText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(color(for: line.text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var lines: [(index: Int, text: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { (index: $0.offset, text: String($0.element)) }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .purple }
        return .secondary
    }
}
