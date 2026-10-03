import SwiftUI
import TheosStudioCore

@MainActor
struct BuildConsoleView: View {

    @ObservedObject var runner: BuildRunner
    let project: Project
    @ObservedObject var store: StudioStore

    var body: some View {
        VStack(spacing: 0) {
            summary
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(runner.lines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(color(for: line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of: runner.lines.count) { count in
                    guard count > 0, let last = runner.lines.last else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Console")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = runner.consoleText
                    } label: {
                        Label("Copy all", systemImage: "doc.on.doc")
                    }
                    Button {
                        runner.clear()
                    } label: {
                        Label("Clear", systemImage: "eraser")
                    }
                } label: {
                    Label("Console options", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    StudioStatusDot(color: phaseColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.headline)
                        Text(phaseText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 7) {
                    StudioPill(text: "\(runner.lines.count) lines", systemImage: "terminal", tint: .secondary)
                    if runner.errorCount > 0 {
                        StudioPill(text: "\(runner.errorCount) error\(runner.errorCount == 1 ? "" : "s")", systemImage: "xmark.octagon.fill", tint: .red)
                    }
                    if runner.warningCount > 0 {
                        StudioPill(text: "\(runner.warningCount) warning\(runner.warningCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    }
                }

                if let artifact = runner.artifact {
                    Label((artifact as NSString).lastPathComponent, systemImage: "shippingbox.fill")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if runner.phase.isRunning {
                    Button(role: .destructive) {
                        runner.cancel()
                    } label: {
                        Label("Cancel Build", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
    }

    private var phaseColor: Color {
        switch runner.phase {
        case .idle: return .secondary
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    private var phaseText: String {
        switch runner.phase {
        case .idle: return "No build has run for \(project.name) yet."
        case .running: return "Running make…"
        case .succeeded: return "Build succeeded."
        case .failed(let status): return "Build failed (exit \(status))."
        case .cancelled: return "Cancelled."
        }
    }

    private func color(for kind: BuildRunner.ConsoleLine.Kind) -> Color {
        switch kind {
        case .command: return .blue
        case .output: return .primary
        case .notice: return .secondary
        }
    }
}

@MainActor
struct InstalledPackagesView: View {

    @ObservedObject var store: StudioStore
    @ObservedObject var installer: PackageInstaller
    @Binding var isPresented: Bool
    @State private var search = ""
    @State private var pendingRemoval: PackageInstaller.InstalledPackage?

    private var filtered: [PackageInstaller.InstalledPackage] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return installer.installed }
        return installer.installed.filter { $0.identifier.lowercased().contains(query) }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    if installer.phase.isRunning {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("Working…").foregroundColor(.secondary)
                        }
                    }
                    ForEach(installer.log.suffix(4), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text(search.isEmpty ? "\(installer.installed.count) installed packages" : "\(filtered.count) matching")
                }

                Section {
                    ForEach(filtered) { package in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(package.identifier).font(.system(size: 12, design: .monospaced))
                                Text(package.version).font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button {
                                pendingRemoval = package
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .searchable(text: $search)
            .listStyle(.insetGrouped)
            .navigationTitle("Installed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { isPresented = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            installer.refreshInstalled(store: store)
                        } label: {
                            Label("Reload list", systemImage: "arrow.clockwise")
                        }
                        Button {
                            installer.respring(store: store)
                        } label: {
                            Label("Respring", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
            .onAppear { installer.refreshInstalled(store: store) }
            .alert(item: $pendingRemoval) { package in
                Alert(
                    title: Text("Remove \(package.identifier)?"),
                    message: Text("This runs dpkg -r. Packages that other packages depend on will leave the device in a state dpkg will complain about."),
                    primaryButton: .destructive(Text("Remove")) {
                        installer.remove(identifier: package.identifier, store: store)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .navigationViewStyle(.stack)
    }
}
