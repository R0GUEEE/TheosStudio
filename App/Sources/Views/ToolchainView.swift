import SwiftUI
import TheosStudioCore

/// What this device can build with, and what to do about what is missing.
///
/// There are two different problems here and they used to be one button:
/// *installing Theos* is copying files into a folder, and *installing the
/// dependency packages* needs root. On a device where the app cannot become root,
/// the first still works — so the screen separates them instead of failing at the
/// first permission error.
@MainActor
struct ToolchainView: View {

    @ObservedObject var store: StudioStore
    @StateObject private var installer = TheosInstallRunner()
    @State private var environmentOverride = ""
    @State private var destination = ""

    private var report: ToolchainReport? { store.toolchain }

    private var defaultDestination: String {
        Paths.documents + "/Theos"
    }

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
                dependencySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Toolchain")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        store.refreshToolchain()
                        store.probePrivileges(force: true)
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                if store.toolchain == nil { store.refreshToolchain() }
                store.probePrivileges()
                environmentOverride = store.settings.theosPathOverride
                if destination.isEmpty { destination = defaultDestination }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Status

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
            DetailRow(
                label: "Jailbreak",
                value: store.jailbreak.rootlessPrefix == nil ? "rootful" : "rootless (\(store.jailbreak.rootlessPrefix!))",
                monospaced: true
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Privileges").font(.footnote).foregroundColor(.secondary)
                Text(store.privileges.summary).font(.footnote)
            }
        } header: {
            Text("This device")
        } footer: {
            Text("A package installed by dpkg needs root, and so does apt-get. Building does not: a project and everything Theos writes during a build live in a folder this app already owns.")
        }
    }

    private func environmentSection(_ report: ToolchainReport) -> some View {
        Section {
            DetailRow(label: "Theos", value: report.theosRoot ?? "not found", monospaced: true)
            DetailRow(
                label: "SDKs",
                value: report.sdkDirectories.isEmpty ? "none" : report.sdkDirectories.joined(separator: ", "),
                monospaced: true
            )
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
                    Image(systemName: status.isInstalled
                          ? "checkmark.circle.fill"
                          : (status.tool.required ? "xmark.circle.fill" : "circle.dashed"))
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

    // MARK: - Installing Theos

    private var installSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install into").font(.footnote).foregroundColor(.secondary)
                TextField("Folder", text: $destination)
                    .font(.system(size: 12, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            if installer.phase.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: installer.progress)
                    Text(phaseText).font(.footnote).foregroundColor(.secondary)
                    Button(role: .destructive) {
                        installer.cancel()
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    installer.start(store: store, destination: destination, installDependencies: true, fetchSDK: true)
                } label: {
                    Label("Install Theos, an SDK and the packages", systemImage: "arrow.down.circle")
                }
                Button {
                    installer.start(store: store, destination: destination, installDependencies: false, fetchSDK: true)
                } label: {
                    Label("Install Theos and an SDK only (no root)", systemImage: "folder.badge.plus")
                }
                Text("The second one needs no root at all: it clones Theos and unpacks an SDK into the folder above. It is what to use when this device will not let the app install packages.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !installer.warnings.isEmpty {
                ForEach(Array(installer.warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(warning).font(.footnote)
                    }
                }
            }

            if !installer.log.isEmpty {
                ConsoleText(lines: installer.log)
                    .frame(height: 240)
                    .cornerRadius(8)
            }
        } header: {
            Text("Install Theos")
        } footer: {
            Text("The official installer refuses to run as root and so does Theos itself, which is why this installs into a folder you own and points Theos at it. It fetches the same patched SDKs from theos/sdks that the official installer does.")
        }
    }

    private var phaseText: String {
        switch installer.phase {
        case .idle: return ""
        case .preparing: return "Looking up the newest SDK…"
        case .working(let label): return "\(label) — step \(installer.completedSteps + 1) of \(installer.totalSteps)"
        case .finished(let message): return message
        case .failed(let message): return message
        case .cancelled: return "Cancelled."
        }
    }

    // MARK: - The part that needs root

    private var dependencySection: some View {
        Section {
            if let report {
                if report.missingPackages.isEmpty {
                    Text("Every package Theos needs is already installed.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text(report.installCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Button {
                            UIPasteboard.general.string = report.installCommand
                        } label: {
                            Label("Copy command", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Button {
                            installer.start(store: store, destination: destination, installDependencies: true, fetchSDK: false)
                        } label: {
                            Label("Install", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!store.privileges.canEscalate || installer.phase.isRunning)
                    }
                }
            } else {
                Text("Rescan to see which packages are missing.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Dependency packages")
        } footer: {
            if store.privileges.canEscalate {
                Text("clang, ldid, dpkg-deb, make, perl and git come from the package manager. These run as \(store.privileges.isRoot ? "root" : "sudo"), which is what makes them installable from here.")
            } else {
                Text(readOnlyFooter)
            }
        }
    }

    private var readOnlyFooter: String {
        let command = store.toolchain?.installCommand ?? "apt-get install -y theos-dependencies"
        return """
        This app is running as mobile and cannot become root, so it cannot install packages for you. \
        Either install the packages from Sileo, or run this in a terminal on the device:

        \(command)
        """
    }
}
