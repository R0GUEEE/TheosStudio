import SwiftUI
import TheosStudioCore

@MainActor
struct SettingsView: View {

    @ObservedObject var store: StudioStore

    private enum SchemeChoice: String, CaseIterable, Identifiable {
        case automatic, rootful, rootless, roothide
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return "Detect from this device"
            case .rootful: return "Rootful"
            case .rootless: return "Rootless"
            case .roothide: return "roothide"
            }
        }
        var scheme: PackagingScheme? {
            switch self {
            case .automatic: return nil
            case .rootful: return .rootful
            case .rootless: return .rootless
            case .roothide: return .roothide
            }
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Folder", text: $store.settings.projectsDirectory)
                        .font(.system(size: 12, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button {
                        store.settings.projectsDirectory = Paths.defaultProjectsDirectory
                        store.reloadProjects()
                    } label: {
                        Label("Use the default folder", systemImage: "arrow.uturn.backward")
                    }
                    Button {
                        try? FS.createDirectory(store.settings.projectsDirectory)
                        store.reloadProjects()
                    } label: {
                        Label("Create it and rescan", systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text("Projects")
                } footer: {
                    Text("Projects are plain directories, so anything a terminal or Filza puts in this folder shows up in the list. \(Paths.defaultProjectsDirectory.removingPrefix(NSHomeDirectory())) is where a new install looks.")
                }

                Section {
                    TextField("Namespace", text: $store.settings.namespace)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Author", text: $store.settings.authorName)
                    TextField("Email", text: $store.settings.authorEmail)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.emailAddress)
                    Picker("Default scheme", selection: Binding(
                        get: { schemeChoice },
                        set: { store.settings.defaultScheme = $0.scheme }
                    )) {
                        ForEach(SchemeChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                } header: {
                    Text("New projects")
                } footer: {
                    Text("The namespace is used to build a package identifier, e.g. com.\(store.settings.namespace).mytweak, so two people's projects do not collide.")
                }

                Section {
                    Toggle("Final package (FINALPACKAGE=1)", isOn: $store.settings.finalPackage)
                    Toggle("Clean before each build", isOn: $store.settings.cleanBeforeBuild)
                    Toggle("Show the commands make runs", isOn: $store.settings.verboseBuild)
                    Stepper(value: $store.settings.jobs, in: 0...16) {
                        Text(store.settings.jobs <= 1
                             ? "Parallel make: off"
                             : "Parallel make: \(store.settings.jobs) jobs")
                    }
                } header: {
                    Text("Building")
                } footer: {
                    Text("Theos does not track header dependencies. If an edit seems to have no effect, turn on cleaning before each build.")
                }

                Section {
                    Stepper(value: $store.settings.editorFontSize, in: 10...20, step: 1) {
                        Text("Editor font size: \(Int(store.settings.editorFontSize)) pt")
                    }
                } header: {
                    Text("Editor")
                }

                Section {
                    Toggle("Respring after installing", isOn: $store.settings.respringAfterInstall)
                    DetailRow(label: "Privileges", value: store.privileges.summary)
                } header: {
                    Text("Installing")
                } footer: {
                    Text("SpringBoard restarts with sbreload when it is installed, and falls back to killall. A respring is what makes a newly installed tweak actually load.")
                }

                Section {
                    NavigationLink(destination: AgentSettingsView(store: store) { }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Assistant", systemImage: "sparkles")
                            Text(store.agent.isConfigured ? store.agent.model : "Not configured")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("AI assistant")
                } footer: {
                    Text("The assistant reads the project, edits it, builds it and installs it — with your approval for anything that writes. It needs an OpenAI-compatible endpoint and a key of your own.")
                }

                Section {
                    DetailRow(label: "Version", value: Self.appVersion)
                    Link(destination: URL(string: "https://github.com/R0GUEEE/TheosStudio")!) {
                        Label("Source and issues", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://theos.dev")!) {
                        Label("Theos documentation", systemImage: "book")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("TheosStudio drives the Theos installed on this device. It does not ship a compiler, and it does not install one except when you ask it to on the Toolchain tab.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
        }
        .navigationViewStyle(.stack)
    }

    private var schemeChoice: SchemeChoice {
        switch store.settings.defaultScheme {
        case .none: return .automatic
        case .some(.rootful): return .rootful
        case .some(.rootless): return .rootless
        case .some(.roothide): return .roothide
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
