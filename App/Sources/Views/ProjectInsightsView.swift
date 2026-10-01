import SwiftUI
import TheosStudioCore

@MainActor
struct ProjectInsightsView: View {
    let project: Project

    private var files: [ProjectFile] {
        FS.projectEntries(at: project.path, depth: 8)
            .filter { !$0.isDirectory && $0.isProbablyText && $0.size <= 1024 * 1024 }
            .compactMap { entry in
                FS.read(project.path + "/" + entry.relativePath).map {
                    ProjectFile(path: entry.relativePath, contents: $0)
                }
            }
    }

    private var health: [ProjectHealthIssue] { ProjectHealth.inspect(files: files) }
    private var metrics: ProjectMetrics { ProjectMetrics.calculate(files: files) }
    private var errors: Int { health.filter { $0.severity == .error }.count }
    private var warnings: Int { health.filter { $0.severity == .warning }.count }

    var body: some View {
        List {
            Section {
                StudioCard {
                    VStack(alignment: .leading, spacing: 14) {
                        StudioSectionTitle(
                            title: errors == 0 ? "Project health looks good" : "Project needs attention",
                            subtitle: summaryText,
                            systemImage: errors == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                        )
                        HStack(spacing: 8) {
                            StudioMetric(title: "Errors", value: "\(errors)", systemImage: "xmark.octagon.fill", tint: .red)
                            StudioMetric(title: "Warnings", value: "\(warnings)", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                            StudioMetric(title: "Files", value: "\(metrics.textFileCount)", systemImage: "doc.text.fill", tint: .blue)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section("Codebase") {
                HStack(spacing: 8) {
                    StudioMetric(title: "Lines", value: "\(metrics.lineCount)", systemImage: "text.alignleft")
                    StudioMetric(title: "Code lines", value: "\(metrics.nonBlankLineCount)", systemImage: "chevron.left.forwardslash.chevron.right", tint: .purple)
                    StudioMetric(title: "Text size", value: ByteCountFormatter.string(fromByteCount: Int64(metrics.bytes), countStyle: .file), systemImage: "internaldrive", tint: .orange)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if !health.isEmpty {
                Section("Issues") {
                    ForEach(health) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(for: issue.severity))
                                .foregroundColor(color(for: issue.severity))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(issue.severity.rawValue.capitalized)
                                        .font(.caption.weight(.semibold))
                                    if let path = issue.path {
                                        Spacer()
                                        Text(path)
                                            .font(.caption2.monospaced())
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Text(issue.message).font(.footnote)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if !metrics.languages.isEmpty {
                Section("Languages") {
                    ForEach(metrics.languages.keys.sorted(), id: \.self) { key in
                        HStack {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            Text(key)
                            Spacer()
                            StatusChip(text: "\(metrics.languages[key] ?? 0)", color: .secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Project Insights")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryText: String {
        if health.isEmpty { return "No structural or packaging issues were detected." }
        return "\(health.count) finding\(health.count == 1 ? "" : "s") across project structure and package metadata."
    }

    private func icon(for severity: ProjectHealthIssue.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .note: return "info.circle.fill"
        }
    }

    private func color(for severity: ProjectHealthIssue.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .note: return .blue
        }
    }
}
