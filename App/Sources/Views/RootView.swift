import SwiftUI
import TheosStudioCore

@main
struct TheosStudioApp: App {
    /// One store for the whole app: the same projects, settings and toolchain
    /// report on every screen.
    @StateObject private var store = StudioStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}

@MainActor
struct RootView: View {

    @ObservedObject var store: StudioStore
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            ProjectListView(store: store)
                .tabItem { Label("Projects", systemImage: "hammer") }
                .tag(0)
            AssistantView(store: store)
                .tabItem { Label("Assistant", systemImage: "sparkles") }
                .tag(1)
            ToolchainView(store: store)
                .tabItem { Label("Toolchain", systemImage: "wrench.and.screwdriver") }
                .tag(2)
            SettingsView(store: store)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
        }
        .alert(item: $store.banner) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.body),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            store.refreshToolchain()
            store.probePrivileges()
            store.reloadProjects()
        }
    }
}

// MARK: - Shared pieces

/// A label/value row that keeps a path or an identifier readable on a phone.
struct DetailRow: View {
    let label: String
    let value: String
    var monospaced = false
    var color: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundColor(.primary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundColor(color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

/// A scrollback view for command output that keeps the newest line visible.
struct ConsoleText: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .background(Color(.secondarySystemBackground))
            .onChange(of: lines.count) { count in
                guard count > 0 else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }
}
