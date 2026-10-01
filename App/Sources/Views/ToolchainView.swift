import SwiftUI
import TheosStudioCore

/// What this device can build with, and how to fix it when it cannot.
///
/// Theos cannot be vendored into an app: a tweak needs the clang, ldid, dpkg-deb
/// and Logos that match the device, and they are all one `apt-get install` away
/// from the package manager the device already has. So this screen's job is to
/// name exactly what is missing and run the install.
@MainActor
struct ToolchainView: View {

    @ObservedObject var store: StudioStore
    @State private var isInstalling = false
    @State private var installLog: [String] = []
    @State private var environmentOverride = ""

    private var report: ToolchainReport? { store.toolchain }

    var body: some View {
        NavigationView {
            List {
                statusSection
                if let report {
                    environmentSection(report)
                    toolsSection(report)
                    if !report.notes.isEmpty { notesSection(report) }
                }
                installSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Toolchain")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        store.refreshToolchain()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                if store.toolchain == nil { store.refreshToolchain() }
                environmentOverride = store.settings.theosPathOverride
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack {
                Image(systemName: store.isReadyToBuild ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(store.isReadyToBuild ? .green : .orange)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isReadyToBuild ? "Ready to build" : "Not ready to build")
                        .font(.headline)
                    Text(store.isReadyToBuild
                         ? "Theos, an SDK and every tool it drives were found."
                         : "Something is missing. Nothing below has been changed for you.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            DetailRow(label: "Jailbreak", value: store.jailbreak.rootlessPrefix == nil ? "rootful" : "rootless (\(store.jailbreak.rootlessPrefix!))", monospaced: true)
            DetailRow(label: "Running as", value: PackageInstaller.isRunningAsRoot ? "root" : "mobile")
        } header: {
            Text("This device")
        } footer: {
            Text("A package installed by dpkg needs root. When this app is run as mobile, dpkg fails with a permission error on the parts of the filesystem it writes; the package can then be installed from Sileo or Zebra instead.")
        }
    }

    private func environmentSection(_ report: ToolchainReport) -> some View {
        Section {
            DetailRow(label: "Theos", value: report.theosRoot ?? "not found", monospaced: true)
            DetailRow(label: "SDKs", value: report.sdkDirectories.isEmpty ? "none" : report.sdkDirectories.joined(separator: ", "), monospaced: true)
            HStack {
                TextField("Theos path", text: $environmentOverride)
                    .font(.system(size: 12, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("Use") {
                    store.settings.theosPathOverride = environmentOverride.trimmingCharacters(in: .whitespaces)
                    store.refreshToolchain()
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("Theos")
        } footer: {
            Text("Searched: /var/jb/opt/theos, /opt/theos, ~/theos, and $THEOS. A directory counts as Theos when it contains makefiles/common.mk.")
        }
    }

    private func toolsSection(_ report: ToolchainReport) -> some View {
        Section {
            ForEach(report.statuses, id: \.tool.name) { status in
                HStack(spacing: 10) {
                    Image(systemName: status.isInstalled ? "checkmark.circle.fill" : (status.tool.required ? "xmark.circle.fill" : "circle.dashed"))
                        .foregroundColor(status.isInstalled ? .green : (status.tool.required ? .red : .secondary))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(status.tool.name)
                            .font(.system(size: 13, design: .monospaced))
                        Text(status.path ?? status.tool.purpose)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !status.tool.required {
                        Text("optional").font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("Tools")
        } footer: {
            Text("Logos is a Perl script, which is why perl is required for any tweak. ldid signs the dylib — without it the injector refuses to load the result.")
        }
    }

    private func notesSection(_ report: ToolchainReport) -> some View {
        Section {
            ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.footnote)
            }
        } header: {
            Text("Notes")
        }
    }

    private var installSection: some View {
        Section {
            if let report, !report.missingPackages.isEmpty {
                Text(report.installCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    runApt([["update"], ["install", "-y"] + report.missingPackages])
                } label: {
                    Label("Install missing packages", systemImage: "arrow.down.circle")
                }
                .disabled(isInstalling)
            }

            Button {
                runApt([["update"], ["install", "-y", "theos"]])
            } label: {
                Label("Install Theos", systemImage: "shippingbox")
            }
            .disabled(isInstalling)

            if isInstalling {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("Running apt-get…").font(.footnote).foregroundColor(.secondary)
                }
            }

            if !installLog.isEmpty {
                ConsoleText(lines: installLog)
                    .frame(height: 220)
                    .cornerRadius(8)
            }
        } header: {
            Text("Fix it here")
        } footer: {
            Text("These run apt-get on this device, the same command a terminal would. If the repository does not carry a package, the app cannot invent it — the output above is the real answer.")
        }
    }

    /// Runs `apt-get` steps one after another. Arguments are passed as an array,
    /// never as a shell string: there is no `/bin/sh` at a path that is the same
    /// across rootful and rootless bootstraps, and `&&` is not an argument.
    private func runApt(_ steps: [[String]]) {
        guard !steps.isEmpty else { return }
        guard let apt = ToolLocator.locate(
            "apt-get",
            in: (store.toolchain?.binDirectories ?? store.jailbreak.binDirectories) + ["/usr/bin", "/bin", "/var/jb/usr/bin"],
            exists: FS.fileExists
        ) else {
            installLog = ["apt-get was not found on this device, so the app cannot install anything for you."]
            return
        }

        isInstalling = true
        var remaining = steps
        let first = remaining.removeFirst()
        installLog.append("$ apt-get " + first.joined(separator: " "))

        let process = ShellProcess(
            executable: apt,
            arguments: first,
            environment: ProcessInfo.processInfo.environment
        )
        do {
            try process.run(onLine: { line in
                self.installLog.append(line)
                if self.installLog.count > 500 {
                    self.installLog.removeFirst()
                }
            }, onExit: { outcome in
                DispatchQueue.main.async {
                    self.installLog.append("— exit \(outcome.status)")
                    if outcome.status != 0 {
                        self.isInstalling = false
                        self.store.refreshToolchain()
                        return
                    }
                    if remaining.isEmpty {
                        self.isInstalling = false
                        self.store.refreshToolchain()
                    } else {
                        self.runApt(remaining)
                    }
                }
            })
        } catch {
            isInstalling = false
            installLog.append(error.localizedDescription)
        }
    }
}
