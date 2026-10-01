import SwiftUI
import TheosStudioCore

// MARK: - Crash logs

/// The device's crash logs, with this project's crashes first.
///
/// A tweak that crashes the process it hooks leaves a report behind, and the
/// report is the only thing that says whether the tweak is actually at fault.
@MainActor
struct CrashLogsView: View {

    @ObservedObject var store: StudioStore
    let project: Project

    @State private var summaries: [CrashLogSummary] = []
    @State private var selected: CrashLogSummary?
    @State private var search = ""

    private var filtered: [CrashLogSummary] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return summaries }
        return summaries.filter {
            $0.process.lowercased().contains(query)
                || ($0.reason ?? "").lowercased().contains(query)
                || ($0.ownFrame ?? "").lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            if summaries.isEmpty {
                Section {
                    Text("No crash logs were found in the usual places. A tweak that only logs does not crash anything, and a device that has never had a crash has nothing here.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    ForEach(filtered) { summary in
                        Button {
                            selected = summary
                        } label: {
                            CrashRow(summary: summary)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("\(filtered.count) log\(filtered.count == 1 ? "" : "s")")
                } footer: {
                    Text("Searched: \(CrashLogParser.candidateDirectories(jailbreak: store.jailbreak, home: NSHomeDirectory()).joined(separator: ", "))")
                }
            }
        }
        .searchable(text: $search)
        .listStyle(.insetGrouped)
        .navigationTitle("Crashes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    reload()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $selected) { summary in
            NavigationView {
                CrashDetailView(summary: summary)
            }
            .navigationViewStyle(.stack)
        }
    }

    private func reload() {
        summaries = CrashService.summaries(
            store: store,
            names: CrashService.interestingNames(for: project)
        )
    }
}

private struct CrashRow: View {
    let summary: CrashLogSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(summary.process).font(.subheadline.weight(.medium))
                if summary.mentionsOurs {
                    StatusChip(text: "this project", color: .red)
                }
                Spacer()
                if let date = summary.date {
                    Text(CrashLogSummary.formatter.string(from: date))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            if let reason = summary.reason {
                Text(reason).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            if let frame = summary.ownFrame {
                Text(frame)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CrashDetailView: View {
    let summary: CrashLogSummary
    @State private var contents: String?
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(summary.path).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)

                if let contents {
                    Text(contents)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text("Could not read the log.")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(summary.process)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Done") { presentation.wrappedValue.dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = contents ?? ""
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
        .onAppear {
            // The tail of an .ips is the interesting part, and the beginning is
            // the JSON header; a phone does not need to render 200 KB of frames.
            guard let text = FS.read(summary.path) else { return }
            contents = text.count > 40_000 ? String(text.suffix(40_000)) : text
        }
    }
}

// MARK: - What is inside a package

/// Reads the .deb the build produced, before it is installed.
@MainActor
struct PackageInspectionView: View {

    @ObservedObject var store: StudioStore
    let project: Project
    let debPath: String

    @State private var rows: [DebSummaryRow] = []
    @State private var entries: [DebEntry] = []
    @State private var listingError: String?
    @State private var missingDependencies: [DependencyGroup] = []
    @State private var checkedDependencies = false

    var body: some View {
        List {
            if let listingError {
                Section {
                    Text(listingError).font(.footnote).foregroundColor(.orange)
                }
            }

            Section {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    DetailRow(label: row.label, value: row.value, monospaced: row.label == "Dylibs" || row.label == "Package")
                }
            } header: {
                Text("Package")
            }

            if checkedDependencies {
                Section {
                    if missingDependencies.isEmpty {
                        Label("Every dependency is installed", systemImage: "checkmark.seal.fill")
                            .font(.footnote)
                            .foregroundColor(.green)
                    } else {
                        ForEach(Array(missingDependencies.enumerated()), id: \.offset) { _, group in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.display).font(.system(size: 12, design: .monospaced))
                                    Text("Not installed — nothing this package depends on is present.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Dependencies")
                } footer: {
                    Text("dpkg installs a package with unmet dependencies and reports nothing later; the tweak then sits there doing nothing. Install the missing packages from Sileo first.")
                }
            }

            if !entries.isEmpty {
                let largest = DebListing.largest(entries)
                Section {
                    ForEach(Array(largest.enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Text(entry.installedPath)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Largest files")
                }

                Section {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        Text(entry.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(entry.isDirectory ? .secondary : .primary)
                    }
                } header: {
                    Text("All \(entries.count) entries")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Inside the package")
        .navigationBarTitleDisplayMode(.inline)
        .task { await inspect() }
    }

    private func inspect() async {
        guard let result = await DpkgService.list(debPath: debPath, store: store) else {
            listingError = "dpkg-deb was not found, so the contents cannot be listed. It comes with the dpkg package."
            return
        }
        guard result.succeeded else {
            listingError = result.output.isEmpty ? "dpkg-deb failed." : result.output
            return
        }
        entries = DebListing.parse(result.output)
        let controlText = await DpkgService.control(debPath: debPath, store: store)?.output ?? ""
        let control = ControlFile.parse(controlText)
        rows = DebListing.summary(entries: entries, control: control, scheme: project.scheme ?? .rootless)

        missingDependencies = await PublishService.missingDependencies(debPath: debPath, store: store)
        checkedDependencies = true
    }
}

/// The `dpkg-deb` calls the app makes.
@MainActor
enum DpkgService {

    static func list(debPath: String, store: StudioStore) async -> CommandResult? {
        await run(["--contents", debPath], store: store)
    }

    static func control(debPath: String, store: StudioStore) async -> CommandResult? {
        // `-f` with no fields prints the whole control file.
        await run(["-f", debPath], store: store)
    }

    private static func run(_ arguments: [String], store: StudioStore) async -> CommandResult? {
        guard let tool = store.toolPaths(for: ["dpkg-deb"])["dpkg-deb"] else { return nil }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let process = ShellProcess(
                executable: tool,
                arguments: arguments,
                environment: store.commandEnvironment()
            )
            var output = ""
            do {
                try process.run(onLine: { line in output += line + "\n" }, onExit: { outcome in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: CommandResult(
                        status: outcome.status,
                        output: output.isEmpty ? outcome.output : output
                    ))
                })
            } catch {
                continuation.resume(returning: CommandResult(status: 127, output: error.localizedDescription))
            }
        }
    }
}

// MARK: - Source control

/// The project's working tree, and the one action worth having here: commit.
@MainActor
struct SourceControlView: View {

    @ObservedObject var store: StudioStore
    let project: Project

    @State private var isRepository = false
    @State private var branch: String?
    @State private var files: [GitFile] = []
    @State private var diffStat = ""
    @State private var message = ""
    @State private var isWorking = false
    @State private var status: String?
    @State private var selectedFile: GitFile?
    @State private var fileDiff = ""

    var body: some View {
        List {
            if !isRepository {
                Section {
                    Text("This project is not a git repository. Initialise one to track changes here, or to push it to GitHub with a terminal.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button {
                        Task { await initialise() }
                    } label: {
                        Label("Initialise repository", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(isWorking)
                } header: {
                    Text("Source control")
                }
            } else {
                Section {
                    if let branch {
                        DetailRow(label: "Branch", value: branch, monospaced: true)
                    }
                    DetailRow(label: "Changes", value: GitPorcelain.summary(files))
                    if !diffStat.isEmpty {
                        Text(diffStat)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Repository")
                }

                if !files.isEmpty {
                    Section {
                        ForEach(files) { file in
                            Button {
                                selectedFile = file
                                Task { await loadDiff(for: file) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.path).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                        Text(file.label).font(.caption2).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Changed files")
                    }
                }

                Section {
                    TextField("Commit message", text: $message)
                    Button {
                        Task { await commit() }
                    } label: {
                        if isWorking {
                            HStack { ProgressView().scaleEffect(0.7); Text("Working…") }
                        } else {
                            Label("Commit everything", systemImage: "checkmark.circle")
                        }
                    }
                    .disabled(isWorking || files.isEmpty || message.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Commit")
                } footer: {
                    Text("Stages every change and commits it as \(store.settings.authorName) <\(store.settings.authorEmail)>. A project this size does not need a staging area.")
                }
            }

            if let status {
                Section {
                    Text(status).font(.footnote).foregroundColor(status.hasPrefix("Committed") ? .green : .red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Source control")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(item: $selectedFile) { file in
            NavigationView {
                ScrollView {
                    Text(fileDiff.isEmpty ? "No diff to show." : fileDiff)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(file.path)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { selectedFile = nil }
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
        .task { await reload() }
    }

    private func reload() async {
        isRepository = GitService.isRepository(project: project.path)
        guard isRepository, GitService.toolPath(store: store) != nil else { return }
        branch = await GitService.branch(project: project.path, store: store)
        files = await GitService.status(project: project.path, store: store)
        diffStat = await GitService.diffStat(project: project.path, store: store)
    }

    private func loadDiff(for file: GitFile) async {
        fileDiff = await GitService.diff(project: project.path, path: file.path, store: store)
        if fileDiff.isEmpty {
            fileDiff = await GitService.diff(project: project.path, path: file.path, staged: true, store: store)
        }
    }

    private func initialise() async {
        isWorking = true
        let result = await GitService.initialise(project: project.path, store: store)
        status = result.succeeded ? "Initialised. Add a remote with git to push it anywhere." : result.output
        isWorking = false
        await reload()
    }

    private func commit() async {
        isWorking = true
        let result = await GitService.commitAll(
            project: project.path,
            message: message.trimmingCharacters(in: .whitespaces),
            store: store
        )
        if result.succeeded {
            status = "Committed."
            message = ""
        } else {
            let tail = result.output.split(separator: "\n").last.map(String.init) ?? "git failed."
            status = tail
        }
        isWorking = false
        await reload()
    }
}

// MARK: - File actions

/// Creating a file — including the half that makes it compile.
@MainActor
struct NewFileSheet: View {

    let project: Project
    let existingPaths: [String]
    @Binding var isPresented: Bool
    var onResult: (ProjectFileEditor.Outcome) -> Void

    @State private var path = ""
    @State private var useTemplate = true
    @State private var addToMakefile = true
    @State private var failure: String?

    private var isSource: Bool { MakefileEditor.isSourceFile(path) }
    private var trimmedPath: String { path.trimmingCharacters(in: .whitespaces) }
    private var alreadyExists: Bool { existingPaths.contains(trimmedPath) }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Path", text: $path)
                        .font(.system(size: 12, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text("New file")
                } footer: {
                    if trimmedPath.isEmpty {
                        Text("Relative to the project root, e.g. Tweak.x or prefs/RootListController.m. Missing folders are created.")
                    } else if alreadyExists {
                        Text("\(trimmedPath) already exists. Pick another name, or open it from the file list.")
                            .foregroundColor(.red)
                    } else if isSource {
                        Text("A source file has to be in the Makefile's file list or it is never compiled. This screen does that for you.")
                    } else {
                        Text("This is not a source file, so the Makefile is left alone.")
                    }
                }

                if isSource {
                    Section {
                        Toggle("Start from a Logos template", isOn: $useTemplate)
                        Toggle("Add to the Makefile's file list", isOn: $addToMakefile)
                    }
                }

                if let failure {
                    Section { Text(failure).font(.footnote).foregroundColor(.red) }
                }
            }
            .navigationTitle("New file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create", action: create).disabled(trimmedPath.isEmpty || alreadyExists)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func create() {
        let contents = useTemplate && isSource
            ? ProjectFileEditor.defaultContents(for: trimmedPath, projectName: project.name)
            : ""
        do {
            let outcome = try ProjectFileEditor.create(
                project: project.path,
                path: trimmedPath,
                contents: contents,
                addToMakefile: addToMakefile
            )
            onResult(outcome)
            isPresented = false
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Renaming a file, and keeping the Makefile pointing at it.
@MainActor
struct RenameFileSheet: View {

    let project: Project
    let entry: ProjectEntry
    @Binding var isPresented: Bool
    var onResult: (ProjectFileEditor.Outcome) -> Void

    @State private var name = ""
    @State private var failure: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("New name", text: $name)
                        .font(.system(size: 12, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text("Rename \(entry.relativePath)")
                } footer: {
                    Text("Renaming a source file also updates the Makefile's file list, or the build would keep compiling the old name and ignore the new one.")
                }
                if let failure {
                    Section { Text(failure).font(.footnote).foregroundColor(.red) }
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Rename", action: rename)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { name = entry.relativePath }
    }

    private func rename() {
        let target = name.trimmingCharacters(in: .whitespaces)
        guard target != entry.relativePath else {
            isPresented = false
            return
        }
        do {
            let outcome = try ProjectFileEditor.rename(project: project.path, from: entry.relativePath, to: target)
            onResult(outcome)
            isPresented = false
        } catch {
            failure = error.localizedDescription
        }
    }
}
