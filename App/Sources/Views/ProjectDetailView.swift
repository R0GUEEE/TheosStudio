import SwiftUI
import TheosStudioCore

@MainActor
struct ProjectDetailView: View {

    @ObservedObject var store: StudioStore
    @StateObject private var runner = BuildRunner()
    @StateObject private var installer = PackageInstaller()
    @State private var current: Project
    @State private var entries: [ProjectEntry] = []
    @State private var installAfterBuild = false
    @State private var isShowingInstalled = false

    init(store: StudioStore, project: Project) {
        _store = ObservedObject(wrappedValue: store)
        _current = State(initialValue: project)
    }

    private var files: [ProjectEntry] {
        // Directories are flattened into their files: a Theos project is five
        // files and a `prefs/` directory, and a tree view would be more taps for
        // less information. `layout/` goes four levels deep, which is the depth.
        entries.filter { !$0.isDirectory }
    }

    private var controlIssues: [ValidationIssue] {
        let control = ControlFile.parse(FS.read(current.path + "/control") ?? "")
        return ControlValidator.issues(for: control, kind: current.kind, projectName: current.name)
    }

    var body: some View {
        List {
            projectSection
            filesSection
            buildSection
            packageSection
            problemsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        runner.build(project: current, store: store)
                    } label: {
                        Label("Build package", systemImage: "hammer")
                    }
                    Button {
                        runner.build(project: current, store: store, cleanOnly: true)
                    } label: {
                        Label("Clean", systemImage: "trash")
                    }
                    Divider()
                    Button {
                        isShowingInstalled = true
                    } label: {
                        Label("Installed packages", systemImage: "shippingbox")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isShowingInstalled) {
            InstalledPackagesView(store: store, installer: installer, isPresented: $isShowingInstalled)
        }
        .sheet(item: $editorTarget) { target in
            NavigationView {
                CodeEditorView(
                    path: target.path,
                    fontSize: CGFloat(store.settings.editorFontSize),
                    scrollToLine: target.line
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done") { editorTarget = nil }
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
        .onAppear(perform: reload)
        .onChange(of: runner.phase) { phase in
            guard case .succeeded = phase else { return }
            let rebuilt = store.load(directory: current.path)
            if let rebuilt { current = rebuilt }
            entries = FS.projectEntries(at: current.path, depth: 5)
            store.reloadProjects()
            if installAfterBuild, let artifact = runner.artifact {
                installAfterBuild = false
                installer.install(debPath: artifact, store: store)
            }
        }
    }

    // MARK: - Sections

    private var projectSection: some View {
        Section {
            DetailRow(label: "Kind", value: current.kind?.displayName ?? "unknown")
            DetailRow(label: "Scheme", value: current.displayScheme, monospaced: true)
            DetailRow(label: "Identifier", value: current.packageIdentifier ?? "—", monospaced: true)
            DetailRow(label: "Version", value: current.version ?? "—", monospaced: true)
            DetailRow(label: "Path", value: current.path.removingPrefix(NSHomeDirectory()), monospaced: true)
        } header: {
            Text("Project")
        }
    }

    private var filesSection: some View {
        Section {
            ForEach(files, id: \.relativePath) { entry in
                if entry.relativePath == "control" {
                    // The one file where a typo costs an install that does
                    // nothing gets a form instead of a text field.
                    NavigationLink(destination: ControlEditorView(
                        path: current.path + "/" + entry.relativePath,
                        kind: current.kind,
                        projectName: current.name
                    )) {
                        FileRow(entry: entry)
                    }
                } else if entry.isProbablyText {
                    NavigationLink(destination: CodeEditorView(
                        path: current.path + "/" + entry.relativePath,
                        fontSize: CGFloat(store.settings.editorFontSize)
                    )) {
                        FileRow(entry: entry)
                    }
                } else {
                    HStack {
                        FileRow(entry: entry)
                        Button {
                            UIApplication.shared.share(URL(fileURLWithPath: current.path + "/" + entry.relativePath))
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if files.isEmpty {
                Text("No files found. Rescan from the project list.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Files")
        } footer: {
            Text("Editing is plain text with syntax colouring. A new source file also has to be added to the Makefile's file list before Theos will compile it.")
        }
    }

    private var buildSection: some View {
        Section {
            Button {
                installAfterBuild = false
                runner.build(project: current, store: store)
            } label: {
                Label("Build package", systemImage: "hammer")
            }
            .disabled(runner.phase.isRunning)

            Button {
                installAfterBuild = true
                runner.build(project: current, store: store)
            } label: {
                Label("Build and install", systemImage: "arrow.down.circle")
            }
            .disabled(runner.phase.isRunning)

            Button {
                runner.build(project: current, store: store, cleanOnly: true)
            } label: {
                Label("Clean build products", systemImage: "trash")
            }
            .disabled(runner.phase.isRunning)

            HStack {
                Text("State")
                Spacer()
                phaseLabel
            }

            NavigationLink(destination: BuildConsoleView(runner: runner, project: current, store: store)) {
                HStack {
                    Label("Console", systemImage: "terminal")
                    Spacer()
                    if runner.errorCount > 0 {
                        StatusChip(text: "\(runner.errorCount) error\(runner.errorCount == 1 ? "" : "s")", color: .red)
                    } else if runner.warningCount > 0 {
                        StatusChip(text: "\(runner.warningCount) warning\(runner.warningCount == 1 ? "" : "s")", color: .orange)
                    } else if !runner.lines.isEmpty {
                        StatusChip(text: "\(runner.lines.count) lines", color: .secondary)
                    }
                }
            }
        } header: {
            Text("Build")
        } footer: {
            Text(buildFooter)
        }
    }

    private var buildFooter: String {
        var notes: [String] = []
        if store.settings.finalPackage {
            notes.append("FINALPACKAGE=1: optimised and stripped.")
        } else {
            notes.append("Debug build. Turn on final packaging in Settings for something to ship.")
        }
        if store.settings.cleanBeforeBuild {
            notes.append("Clean before every build.")
        }
        if !store.isReadyToBuild {
            notes.append("This device is not fully set up — see the Toolchain tab.")
        }
        return notes.joined(separator: " ")
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch runner.phase {
        case .idle:
            Text("idle").foregroundColor(.secondary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("running make").foregroundColor(.secondary)
            }
        case .succeeded:
            Text(runner.artifact != nil ? "built" : "done").foregroundColor(.green)
        case .failed(let status):
            Text("failed (exit \(status))").foregroundColor(.red)
        case .cancelled:
            Text("cancelled").foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var packageSection: some View {
        if let artifact = runner.artifact ?? current.builtPackage {
            Section {
                DetailRow(label: "Package", value: (artifact as NSString).lastPathComponent, monospaced: true)
                if let date = FS.modificationDate(artifact) {
                    DetailRow(label: "Built", value: Self.dateFormatter.string(from: date))
                }
                DetailRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(FS.size(artifact)), countStyle: .file))

                if installer.phase.isRunning {
                    HStack {
                        ProgressView().scaleEffect(0.8)
                        Text(installerMessage).font(.footnote).foregroundColor(.secondary)
                    }
                } else {
                    Button {
                        installer.install(debPath: artifact, store: store)
                    } label: {
                        Label("Install with dpkg", systemImage: "arrow.down.to.line")
                    }
                    Button {
                        UIApplication.shared.share(URL(fileURLWithPath: artifact))
                    } label: {
                        Label("Share or open in Sileo", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        installer.respring(store: store)
                    } label: {
                        Label("Respring", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                if case .failed(let reason) = installer.phase {
                    Text(reason).font(.footnote).foregroundColor(.red)
                }
                ForEach(installer.log.suffix(6), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Package")
            } footer: {
                Text("dpkg installs the package exactly as Sileo would. The .deb stays in the project's packages/ folder.")
            }
        }
    }

    private var installerMessage: String {
        switch installer.phase {
        case .working(let what): return "\(what)…"
        case .finished(let what): return what
        case .failed: return "failed"
        case .idle: return ""
        }
    }

    @ViewBuilder
    private var problemsSection: some View {
        if !controlIssues.isEmpty {
            Section {
                ForEach(Array(controlIssues.enumerated()), id: \.offset) { _, issue in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: issue.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(issue.severity == .error ? .red : .orange)
                        Text(issue.message).font(.footnote)
                    }
                }
            } header: {
                Text("control file")
            } footer: {
                Text("These are the fields dpkg rejects, plus the two mistakes that produce a package that installs and then does nothing.")
            }
        }

        if !runner.diagnostics.isEmpty {
            Section {
                ForEach(Array(runner.diagnostics.prefix(12).enumerated()), id: \.offset) { _, diagnostic in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : (diagnostic.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"))
                            .foregroundColor(diagnostic.severity == .error ? .red : (diagnostic.severity == .warning ? .orange : .secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostic.message).font(.footnote)
                            if let location = diagnostic.location {
                                Text(location)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Best effort: the compiler prints paths relative to the
                        // project, which is exactly where the editor looks.
                        if let file = diagnostic.file {
                            editorTarget = EditorTarget(path: resolved(file), line: diagnostic.line)
                        }
                    }
                }
                if runner.diagnostics.count > 12 {
                    Text("\(runner.diagnostics.count - 12) more in the console")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Build problems")
            }
        }
    }

    @State private var editorTarget: EditorTarget?

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let path: String
        let line: Int?
    }

    private func resolved(_ file: String) -> String {
        file.hasPrefix("/") ? file : (current.path as NSString).appendingPathComponent(file)
    }

    // MARK: - Loading

    private func reload() {
        if let rebuilt = store.load(directory: current.path) {
            current = rebuilt
        }
        entries = FS.projectEntries(at: current.path, depth: 5)
        store.refreshToolchain()
        installer.refreshInstalled(store: store)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct FileRow: View {
    let entry: ProjectEntry

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(entry.relativePath)
                .font(.system(size: 12, design: .monospaced))
            Spacer()
            if entry.size > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var icon: String {
        switch entry.language {
        case .code: return "curlybraces"
        case .makefile: return "hammer"
        case .controlFile: return "list.bullet.rectangle"
        case .plist: return "doc.badge.gearshape"
        case .plainText: return entry.relativePath.hasSuffix(".deb") ? "shippingbox" : "doc.text"
        }
    }
}
