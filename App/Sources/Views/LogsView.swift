import SwiftUI
import TheosStudioCore

/// The device's own log, filtered to this tweak.
///
/// A crash log says a tweak fell over; the system log says what it was doing just
/// before — the `NSLog` lines the tweak wrote itself. Whether the device keeps one
/// depends on the bootstrap, so this says plainly when there is nothing to read
/// rather than showing an empty screen.
@MainActor
struct LogsView: View {

    @ObservedObject var store: StudioStore
    let project: Project

    @State private var path: String?
    @State private var lines: [String] = []
    @State private var query = ""
    @State private var follow = true
    @State private var timer: Timer?

    private var candidates: [String] {
        DeviceLogs.candidatePaths(jailbreak: store.jailbreak, home: NSHomeDirectory())
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if path == nil {
                emptyState
            } else {
                ConsoleText(lines: lines)
            }
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Toggle("Follow", isOn: $follow)
                    Button {
                        UIPasteboard.general.string = lines.joined(separator: "\n")
                    } label: {
                        Label("Copy what is shown", systemImage: "doc.on.doc")
                    }
                } label: {
                    Label("Log options", systemImage: "ellipsis.circle")
                }
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: follow) { _ in follow ? start() : stop() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundColor(.secondary)
                TextField("Filter", text: $query)
                    .font(.system(size: 12, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onChange(of: query) { _ in refresh() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        refresh()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let path {
                Text(path).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No log to read", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            Text("This bootstrap does not keep a system log where the app looks. That is normal on some jailbreaks: `syslogd` is not part of every bootstrap, and without it nothing writes the file.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("Looked in:")
                .font(.caption)
                .foregroundColor(.secondary)
            ForEach(candidates, id: \.self) { candidate in
                Text(candidate).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            }
            Text("Crash logs are the other half of this, and they are always there — see the Crashes screen.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Reading

    private func start() {
        query = DeviceLogs.defaultQuery(name: project.name)
        findLog()
        refresh()
        guard follow, timer == nil else { return }
        // A log is a file someone else is appending to; polling is how you read it
        // without a syslog protocol on the other end.
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func findLog() {
        path = candidates.first { FS.fileExists($0) && FS.size($0) > 0 }
    }

    private func refresh() {
        guard let path, let contents = FS.read(path) else {
            lines = []
            return
        }
        let tail = DeviceLogs.tail(contents, lines: 2000)
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            lines = tail
        } else {
            lines = tail.filter { $0.range(of: query, options: .caseInsensitive) != nil }
        }
    }
}
