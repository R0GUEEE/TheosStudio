import SwiftUI
import TheosStudioCore

@MainActor
struct ProjectListView: View {

    @ObservedObject var store: StudioStore
    @State private var isCreating = false
    @State private var pendingDeletion: Project?

    var body: some View {
        NavigationView {
            List {
                if store.projects.isEmpty {
                    Section {
                        EmptyProjectsView(store: store, isCreating: $isCreating)
                    }
                } else {
                    Section(header: Text("\(store.projects.count) project\(store.projects.count == 1 ? "" : "s")")) {
                        ForEach(store.projects) { project in
                            NavigationLink(destination: ProjectDetailView(store: store, project: project)) {
                                ProjectRow(project: project)
                            }
                        }
                        .onDelete { offsets in
                            if let index = offsets.first {
                                pendingDeletion = store.projects[index]
                            }
                        }
                    }
                }

                Section(footer: Text("Projects live in \(store.settings.projectsDirectory.removingPrefix(NSHomeDirectory())). Every folder with a Makefile and a control file shows up here, including ones you copy in from Filza or a terminal.")) {
                    Button {
                        store.reloadProjects()
                        store.refreshToolchain()
                    } label: {
                        Label("Rescan project folder", systemImage: "arrow.clockwise")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("TheosStudio")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isCreating = true
                    } label: {
                        Label("New project", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isCreating) {
                NewProjectView(store: store, isPresented: $isCreating)
            }
            .alert(item: $pendingDeletion) { project in
                Alert(
                    title: Text("Delete \(project.name)?"),
                    message: Text("This removes \(project.path.removingPrefix(NSHomeDirectory())) and everything in it, including any built packages. There is no undo."),
                    primaryButton: .destructive(Text("Delete")) {
                        do {
                            try store.deleteProject(project)
                        } catch {
                            store.banner = BannerMessage(title: "Could not delete", body: error.localizedDescription)
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct EmptyProjectsView: View {
    @ObservedObject var store: StudioStore
    @Binding var isCreating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No projects yet")
                .font(.headline)
            Text("Create one and TheosStudio writes the same files `nic.pl` would — a Makefile, a control file, a Logos source and an injection filter — plus a README that says what the packaging scheme it was generated for means.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Button {
                isCreating = true
            } label: {
                Label("New project", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 6)
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(project.name)
                    .font(.headline)
                Spacer()
                StatusChip(text: project.displayScheme, color: project.scheme == .rootless ? .blue : .gray)
            }
            HStack(spacing: 6) {
                if let kind = project.kind {
                    Text(kind.displayName)
                } else {
                    Text("Unknown kind")
                }
                if let version = project.version {
                    Text("· \(version)")
                }
                if project.builtPackage != nil {
                    Text("· built")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            if let identifier = project.packageIdentifier {
                Text(identifier)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

extension String {
    /// `~/Documents/Projects` rather than the full absolute path, where it helps.
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? "~" + dropFirst(prefix.count) : self
    }
}
