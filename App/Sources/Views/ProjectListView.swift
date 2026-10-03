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
                workspaceSection
                projectSection
                utilitySection
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 50)
            .searchable(text: $search, prompt: "Search projects")
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        store.reloadProjects()
                        store.refreshToolchain()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh workspace")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { isCreating = true } label: {
                        Label("New Project", systemImage: "plus")
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

    private var workspaceSection: some View {
        Section {
            StudioHero(
                eyebrow: "TheosStudio",
                title: "On-device development",
                subtitle: store.isReadyToBuild
                    ? "Your toolchain is ready. Pick up a project or start something new."
                    : "Your workspace is available, but the toolchain needs attention before you build.",
                systemImage: store.isReadyToBuild ? "hammer.fill" : "wrench.and.screwdriver.fill",
                tint: store.isReadyToBuild ? .indigo : .orange
            ) {
                HStack(spacing: 8) {
                    StudioPill(
                        text: store.isReadyToBuild ? "Build ready" : "Setup needed",
                        systemImage: store.isReadyToBuild ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: store.isReadyToBuild ? .green : .orange
                    )
                    StudioPill(
                        text: "\(store.projects.count) projects",
                        systemImage: "square.stack.3d.up",
                        tint: .indigo
                    )
                }

                HStack(spacing: 8) {
                    StudioMetric(title: "Projects", value: "\(store.projects.count)", systemImage: "folder.fill", tint: .indigo)
                    StudioMetric(title: "Packages", value: "\(builtCount)", systemImage: "shippingbox.fill", tint: .green)
                    StudioMetric(title: "Rootless", value: "\(rootlessCount)", systemImage: "lock.open.fill", tint: .blue)
                }

                StudioActionButton(title: "Create Project", systemImage: "plus", prominent: true) {
                    isCreating = true
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var projectSection: some View {
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
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingDeletion = project } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text(search.isEmpty ? "Recent Projects" : "Search Results")
                    Spacer()
                    Text("\(filteredProjects.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var utilitySection: some View {
        Section {
            Button {
                store.reloadProjects()
                store.refreshToolchain()
            } label: {
                Label("Rescan Workspace", systemImage: "arrow.clockwise")
            }
        } footer: {
            Text(store.settings.projectsDirectory.removingPrefix(NSHomeDirectory()))
                .font(.caption2)
                .textSelection(.enabled)
        }
    }
}

private struct ProjectCard: View {
    let project: Project
    private var tint: Color { StudioUI.schemeColor(project.displayScheme) }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.12))
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(tint)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.headline)
                        .lineLimit(1)
                    if project.builtPackage != nil {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                HStack(spacing: 5) {
                    Text(project.kind?.displayName ?? "Unknown")
                    if let version = project.version { Text("· v\(version)") }
                    Text("·")
                    Text(project.displayScheme)
                        .foregroundColor(tint)
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

            Spacer(minLength: 6)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.75)
        )
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
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? "~" + dropFirst(prefix.count) : self
    }
}
