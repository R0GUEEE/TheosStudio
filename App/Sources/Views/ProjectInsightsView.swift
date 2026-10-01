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

    var body: some View {
        List {
            Section("Health") {
                if health.isEmpty {
                    Label("No project-level problems found", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    ForEach(health) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: icon(for: issue.severity))
                                    .foregroundColor(color(for: issue.severity))
                                Text(issue.severity.rawValue.capitalized)
                                    .font(.caption.bold())
                                if let path = issue.path {
                                    Spacer()
                                    Text(path)
                                        .font(.caption2.monospaced())
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(issue.message).font(.footnote)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Metrics") {
                metric("Text files", "\(metrics.textFileCount)")
                metric("Lines", "\(metrics.lineCount)")
                metric("Non-blank lines", "\(metrics.nonBlankLineCount)")
                metric("Text size", ByteCountFormatter.string(fromByteCount: Int64(metrics.bytes), countStyle: .file))
            }

            if !metrics.languages.isEmpty {
                Section("Languages") {
                    ForEach(metrics.languages.keys.sorted(), id: \.self) { key in
                        metric(key, "\(metrics.languages[key] ?? 0)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Project Insights")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary).monospacedDigit()
        }
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
        case .note: return .secondary
        }
    }
}
