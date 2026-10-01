import SwiftUI
import TheosStudioCore

@MainActor
struct ProjectListView: View {

    @ObservedObject var store: StudioStore
    @State private var isCreating = false
    @State private var pendingDeletion: Project?
    @State private var search = ""

    private var filteredProjects: [Project] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.projects }
        return store.projects.filter { project in
            project.name.lowercased().contains(query)
                || (project.packageIdentifier?.lowercased().contains(query) ?? false)
                || (project.kind?.displayName.lowercased().contains(query) ?? false)
                || project.displayScheme.lowercased().contains(query)
        }
    }

    private var builtCount: Int { store.projects.filter { $0.builtPackage != nil }.count }
    private var rootlessCount: Int { store.projects.filter { $0.scheme == .rootless }.count }

    var body: some View {
        NavigationView {
            List {
                overviewSection

                if store.projects.isEmpty {
                    Section {
                        StudioEmptyState(
                            systemImage: "hammer.circle",
                            title: "No projects yet",
                            message: "Create a Theos project here, or copy an existing project into the configured projects folder.",
                            actionTitle: "Create Project",
                            action: { isCreating = true }
                        )
                    }
                    .listRowBackground(Color.clear)
                } else if filteredProjects.isEmpty {
                    Section {
                        StudioEmptyState(
                            systemImage: "magnifyingglass",
                            title: "No matches",
                            message: "No project matches “\(search)”."
                        )
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(filteredProjects) { project in
                            NavigationLink(destination: ProjectDetailView(store: store, project: project)) {
                                ProjectCard(project: project)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 12))
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeletion = project
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text(search.isEmpty
                             ? "\(store.projects.count) Project\(store.projects.count == 1 ? "" : "s")"
                             : "\(filteredProjects.count) Result\(filteredProjects.count == 1 ? "" : "s")")
                    }
                }

                Section {
                    Button {
                        store.reloadProjects()
                        store.refreshToolchain()
                    } label: {
                        Label("Rescan Projects & Toolchain", systemImage: "arrow.clockwise")
                    }
                } footer: {
                    Text("Projects folder: \(store.settings.projectsDirectory.removingPrefix(NSHomeDirectory()))")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Projects, identifiers, kinds")
            .navigationTitle("TheosStudio")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isCreating = true
                    } label: {
                        Label("New project", systemImage: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $isCreating) {
                NewProjectView(store: store, isPresented: $isCreating)
            }
            .alert(item: $pendingDeletion) { project in
                Alert(
                    title: Text("Delete \(project.name)?"),
                    message: Text("This removes \(project.path.removingPrefix(NSHomeDirectory())) and everything in it, including built packages. There is no undo."),
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

    private var overviewSection: some View {
        Section {
            StudioCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Workspace")
                                .font(.title3.weight(.bold))
                            Text(store.isReadyToBuild ? "Ready to build on this device" : "Toolchain needs attention")
                                .font(.caption)
                                .foregroundColor(store.isReadyToBuild ? .green : .orange)
                        }
                        Spacer()
                        Image(systemName: store.isReadyToBuild ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill")
                            .font(.title2)
                            .foregroundColor(store.isReadyToBuild ? .green : .orange)
                    }

                    HStack(spacing: 8) {
                        StudioMetric(title: "Projects", value: "\(store.projects.count)", systemImage: "square.stack.3d.up")
                        StudioMetric(title: "Built", value: "\(builtCount)", systemImage: "shippingbox.fill", tint: .green)
                        StudioMetric(title: "Rootless", value: "\(rootlessCount)", systemImage: "lock.open.fill", tint: .blue)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }
}

private struct ProjectCard: View {
    let project: Project

    private var tint: Color { StudioUI.schemeColor(project.displayScheme) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.12))
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(tint)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.headline)
                        .lineLimit(1)
                    if project.builtPackage != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                HStack(spacing: 6) {
                    Text(project.kind?.displayName ?? "Unknown")
                    if let version = project.version { Text("• v\(version)") }
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if let identifier = project.packageIdentifier {
                    Text(identifier)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            StatusChip(text: project.displayScheme, color: tint)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch project.kind?.rawValue.lowercased() {
        case "tweak": return "puzzlepiece.extension.fill"
        case "application": return "app.fill"
        case "tool": return "terminal.fill"
        case "preferencebundle", "preference_bundle": return "switch.2"
        default: return "hammer.fill"
        }
    }
}

extension String {
    /// `~/Documents/Projects` rather than the full absolute path, where it helps.
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? "~" + dropFirst(prefix.count) : self
    }
}
