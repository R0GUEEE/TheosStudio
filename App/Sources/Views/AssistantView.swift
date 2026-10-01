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
            privilegesCanEscalate: store.privileges.canEscalate,
            toolchainSummary: toolchainSummary
        )
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
