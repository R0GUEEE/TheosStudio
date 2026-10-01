import SwiftUI
import TheosStudioCore

// MARK: - Publishing

/// Turns the project's built packages into a repository.
///
/// The whole format is three files and a folder, which is why this is worth
/// having on the device: build a tweak, publish it, and add the URL to Sileo —
/// without a Mac. Push the folder to GitHub Pages (or any web server) and it is a
/// source anyone can add, because the index records the size and hash of every
/// package, and a wrong hash is a package that downloads and then refuses to
/// install.
@MainActor
struct RepositoryExportView: View {

    @ObservedObject var store: StudioStore
    let project: Project

    @State private var label = ""
    @State private var description = ""
    @State private var directory = ""
    @State private var isWorking = false
    @State private var result: PublishService.ExportResult?
    @State private var failure: String?
    @State private var artifactCount = 0

    var body: some View {
        Form {
            Section {
                TextField("Repository name", text: $label)
                TextField("Description", text: $description)
                TextField("Folder", text: $directory)
                    .font(.system(size: 12, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } header: {
                Text("Repository")
            } footer: {
                Text("\(artifactCount) package\(artifactCount == 1 ? "" : "s") will be published. The folder is created if it does not exist; point a web server or GitHub Pages at it.")
            }

            Section {
                Button {
                    Task { await export() }
                } label: {
                    if isWorking {
                        HStack { ProgressView().scaleEffect(0.7); Text("Writing…") }
                    } else {
                        Label("Write the repository", systemImage: "shippingbox")
                    }
                }
                .disabled(isWorking || artifactCount == 0)

                if let result {
                    DetailRow(label: "Packages", value: "\(result.packages)")
                    ForEach(result.files, id: \.self) { file in
                        Text(file).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    }
                    Button {
                        UIApplication.shared.share(URL(fileURLWithPath: result.directory))
                    } label: {
                        Label("Share the folder", systemImage: "square.and.arrow.up")
                    }
                    ForEach(result.warnings, id: \.self) { warning in
                        Text(warning).font(.footnote).foregroundColor(.orange)
                    }
                }

                if let failure {
                    Text(failure).font(.footnote).foregroundColor(.red)
                }
            } header: {
                Text("Write")
            } footer: {
                Text("What a package manager reads: Packages (the index), Release (what the repo is), debs/ (the packages) and an index.html for the people who open the URL in a browser. Sileo and Zebra read the uncompressed index, so there is nothing to gzip.")
            }
        }
        .navigationTitle("Publish a repository")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            artifactCount = PublishService.artifacts(project: project).count
            if label.isEmpty { label = project.name }
            if description.isEmpty { description = "\(project.name) — built on device with TheosStudio." }
            if directory.isEmpty { directory = Paths.documents + "/Repo" }
        }
    }

    private func export() async {
        isWorking = true
        failure = nil
        result = nil
        do {
            result = try await PublishService.export(
                project: project,
                store: store,
                directory: directory,
                label: label,
                description: description
            )
        } catch {
            failure = error.localizedDescription
        }
        isWorking = false
    }
}

// MARK: - Built packages

/// Every package this project has built, with the actions that matter: install
/// the one you want, share it, or check what is inside it.
@MainActor
struct ArtifactsView: View {

    @ObservedObject var store: StudioStore
    let project: Project

    @StateObject private var installer = PackageInstaller()
    @State private var artifacts: [BuildArtifact] = []
    @State private var pendingDeletion: BuildArtifact?
    @State private var bumpResult: String?
    @State private var isShowingRepository = false

    var body: some View {
        List {
            if artifacts.isEmpty {
                Section {
                    Text("No packages yet. Build the project and its .deb appears here — keeping them is what makes “it worked ten minutes ago” a question with an answer.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    ForEach(artifacts) { artifact in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(artifact.version)
                                    .font(.system(size: 13, design: .monospaced))
                                StatusChip(text: artifact.architecture, color: .blue)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(artifact.size), countStyle: .file))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            if let date = artifact.date {
                                Text(CrashLogSummary.formatter.string(from: date))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            HStack(spacing: 14) {
                                Button {
                                    installer.install(debPath: artifact.path, store: store)
                                } label: {
                                    Label("Install", systemImage: "arrow.down.to.line")
                                }
                                .buttonStyle(.borderless)
                                .disabled(installer.phase.isRunning)

                                Button {
                                    UIApplication.shared.share(URL(fileURLWithPath: artifact.path))
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderless)
                            }
                            .font(.footnote)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDeletion = artifact
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("\(artifacts.count) package\(artifacts.count == 1 ? "" : "s")")
                }

                Section {
                    installerState
                    ForEach(installer.log.suffix(4), id: \.self) { line in
                        Text(line).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    }
                }

                Section {
                    Button {
                        bumpVersion()
                    } label: {
                        Label("Bump the version and rebuild next time", systemImage: "arrow.up.circle")
                    }
                    NavigationLink(destination: RepositoryExportView(store: store, project: project)) {
                        Label("Publish a repository", systemImage: "shippingbox")
                    }
                } header: {
                    Text("Release")
                } footer: {
                    if let bumpResult {
                        Text(bumpResult)
                    } else {
                        Text("dpkg will not upgrade a package to a version it considers equal, so rebuilding without bumping installs nothing and says nothing.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Built packages")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .alert(item: $pendingDeletion) { artifact in
            Alert(
                title: Text("Delete \(artifact.fileName)?"),
                message: Text("The package is removed from the project's packages folder."),
                primaryButton: .destructive(Text("Delete")) {
                    try? FS.remove(artifact.path)
                    reload()
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func reload() {
        artifacts = PublishService.artifacts(project: project)
    }

    /// What the installer is doing, where the button that started it is.
    @ViewBuilder
    private var installerState: some View {
        switch installer.phase {
        case .working(let what):
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("\(what)…").font(.footnote).foregroundColor(.secondary)
            }
        case .failed(let reason):
            Text(reason).font(.footnote).foregroundColor(.red)
        case .finished(let message):
            Text(message).font(.footnote).foregroundColor(.green)
        case .idle:
            EmptyView()
        }
    }

    /// Bumps `Version:` in the control file, which is what the next build stamps
    /// into the package name.
    private func bumpVersion() {
        let path = project.path + "/control"
        guard let text = FS.read(path) else {
            bumpResult = "There is no control file to bump."
            return
        }
        var control = ControlFile.parse(text)
        let current = control.version ?? "0.0.1"
        let bumped = DebianVersion.bumped(current)
        control["Version"] = bumped
        do {
            try FS.write(control.serialized(), to: path)
            bumpResult = "Version \(current) → \(bumped). Build again to produce it."
        } catch {
            bumpResult = "Could not write control: \(error.localizedDescription)"
        }
    }
}

// MARK: - Search

/// Find anything in the project.
@MainActor
struct ProjectSearchView: View {

    @ObservedObject var store: StudioStore
    let project: Project

    @State private var query = ""
    @State private var caseSensitive = false
    @State private var matches: [ProjectMatch] = []
    @State private var editorTarget: ProjectMatch?

    private var groups: [(path: String, matches: [ProjectMatch])] {
        ProjectSearch.grouped(matches)
    }

    var body: some View {
        List {
            Section {
                Toggle("Match case", isOn: $caseSensitive)
                    .onChange(of: caseSensitive) { _ in search() }
            }

            if query.isEmpty {
                Section {
                    Text("Search the whole project — five files, so the answer is which file and line, not a ranked list.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if matches.isEmpty {
                Section {
                    Text("Nothing matches “\(query)”.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(groups, id: \.path) { group in
                    Section {
                        ForEach(group.matches) { match in
                            Button {
                                editorTarget = match
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(match.text.trimmingCharacters(in: .whitespaces))
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(2)
                                    Text("line \(match.line), column \(match.column)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("\(group.path) — \(group.matches.count)")
                    }
                }
            }
        }
        .searchable(text: $query)
        .onChange(of: query) { _ in search() }
        .listStyle(.insetGrouped)
        .navigationTitle("Find in project")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editorTarget) { match in
            NavigationView {
                CodeEditorView(
                    path: project.path + "/" + match.path,
                    fontSize: CGFloat(store.settings.editorFontSize),
                    scrollToLine: match.line
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done") { editorTarget = nil }
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
    }

    private func search() {
        let files = FS.projectEntries(at: project.path, depth: 5)
            .filter { !$0.isDirectory && $0.isProbablyText && $0.size < 512 * 1024 }
            .compactMap { entry -> ProjectFile? in
                guard let contents = FS.read(project.path + "/" + entry.relativePath) else { return nil }
                return ProjectFile(path: entry.relativePath, contents: contents)
            }
        matches = ProjectSearch.matches(in: files, query: query, caseSensitive: caseSensitive)
    }
}
