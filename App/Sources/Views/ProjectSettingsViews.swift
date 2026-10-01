import SwiftUI
import TheosStudioCore

/// The build settings people actually change, as a form.
///
/// The alternative is editing the Makefile by hand, which is fine right up until
/// the moment a value has to be exactly right (an SDK version, an architecture
/// list) and a typo produces a build error fifty lines later.
@MainActor
struct MakefileSettingsView: View {

    @ObservedObject var store: StudioStore
    let project: Project

    @State private var settings = MakefileEditor.Settings()
    @State private var extraVariables: [(name: String, value: String)] = []
    @State private var newName = ""
    @State private var newValue = ""
    @State private var loadFailure: String?
    @State private var saved: String?

    private var makefilePath: String { project.path + "/Makefile" }

    var body: some View {
        Form {
            Section {
                TextField("TARGET", text: $settings.target)
                    .font(.system(size: 12, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("ARCHS", text: $settings.architectures)
                    .font(.system(size: 12, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("INSTALL_TARGET_PROCESSES", text: $settings.installTargetProcesses)
                    .font(.system(size: 12, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } header: {
                Text("Build")
            } footer: {
                Text("TARGET is the SDK and minimum iOS version Theos compiles against (`iphone:clang:latest:15.0`). ARCHS needs arm64e for hooks inside system processes on A12 and newer. INSTALL_TARGET_PROCESSES is what `make install` restarts — the same list the Restart section uses.")
            }

            Section {
                ForEach(Array(extraVariables.enumerated()), id: \.offset) { index, variable in
                    HStack {
                        Text(variable.name)
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Text(variable.value)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            settings.extraVariables[variable.name] = nil
                            extraVariables.remove(at: index)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }

                HStack {
                    TextField("NAME", text: $newName)
                        .font(.system(size: 12, design: .monospaced))
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                    Text("=").foregroundColor(.secondary)
                    TextField("value", text: $newValue)
                        .font(.system(size: 12, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Add") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        let value = newValue.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, !value.isEmpty else { return }
                        settings.extraVariables[name] = value
                        extraVariables.append((name, value))
                        newName = ""
                        newValue = ""
                    }
                    .buttonStyle(.borderless)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                              || newValue.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Extra make variables")
            } footer: {
                Text("`DEBUG = 0`, `FINALPACKAGE = 1`, `THEOS_PACKAGE_SCHEME = roothide` — anything Theos reads on the command line can be pinned here instead.")
            }

            Section {
                Button(action: save) {
                    Label("Save the Makefile", systemImage: "square.and.arrow.down")
                }
                if let saved {
                    Text(saved).font(.footnote).foregroundColor(.green)
                }
                if let loadFailure {
                    Text(loadFailure).font(.footnote).foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Build settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        guard let text = FS.read(makefilePath) else {
            loadFailure = "There is no Makefile in this project."
            return
        }
        settings = MakefileEditor.settings(in: text)
        extraVariables = settings.extraVariables
            .map { (name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private func save() {
        guard let text = FS.read(makefilePath) else {
            loadFailure = "There is no Makefile in this project."
            return
        }
        let result = MakefileEditor.applying(settings, to: text)
        guard result.changed else {
            saved = result.reason ?? "Nothing to change."
            return
        }
        do {
            try FS.write(result.text, to: makefilePath)
            saved = "Saved."
            loadFailure = nil
        } catch {
            loadFailure = "Could not write the Makefile: \(error.localizedDescription)"
        }
    }
}

/// The injection filter, as a form.
///
/// This is the file that decides whether the tweak loads at all, and the two ways
/// to get it wrong are both silent: nothing listed means the dylib is injected
/// into every process on the device, and a bundle identifier that does not exist
/// means it is never injected at all.
@MainActor
struct InjectionFilterView: View {

    @ObservedObject var store: StudioStore
    let project: Project

    @State private var filter = InjectionFilter()
    @State private var newBundle = ""
    @State private var newExecutable = ""
    @State private var saved: String?
    @State private var loadFailure: String?

    private var path: String { project.path + "/\(project.name).plist" }

    var body: some View {
        Form {
            Section {
                ForEach(filter.bundles, id: \.self) { bundle in
                    HStack {
                        Image(systemName: "app").foregroundColor(.secondary)
                        Text(bundle).font(.system(size: 12, design: .monospaced))
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            filter.remove(bundle: bundle)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                HStack {
                    TextField("com.apple.springboard", text: $newBundle)
                        .font(.system(size: 12, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Add") {
                        filter.add(bundle: newBundle.trimmingCharacters(in: .whitespaces))
                        newBundle = ""
                    }
                    .buttonStyle(.borderless)
                    .disabled(newBundle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Bundles (\(filter.bundles.count))")
            } footer: {
                Text("The apps and system processes that load the tweak. One bundle identifier is the usual answer; the fewer, the less that can go wrong.")
            }

            Section {
                ForEach(filter.executables, id: \.self) { executable in
                    HStack {
                        Image(systemName: "gearshape.2").foregroundColor(.secondary)
                        Text(executable).font(.system(size: 12, design: .monospaced))
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            filter.remove(executable: executable)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                HStack {
                    TextField("backboardd", text: $newExecutable)
                        .font(.system(size: 12, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Add") {
                        filter.add(executable: newExecutable.trimmingCharacters(in: .whitespaces))
                        newExecutable = ""
                    }
                    .buttonStyle(.borderless)
                    .disabled(newExecutable.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Executables (\(filter.executables.count))")
            } footer: {
                Text("For daemons that have no bundle identifier. Most tweaks do not need this.")
            }

            if !filter.warnings.isEmpty {
                Section {
                    ForEach(Array(filter.warnings.enumerated()), id: \.offset) { _, warning in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(warning).font(.footnote)
                        }
                    }
                } header: {
                    Text("Worth knowing")
                }
            }

            Section {
                Button(action: save) {
                    Label("Save \(project.name).plist", systemImage: "square.and.arrow.down")
                }
                if let saved {
                    Text(saved).font(.footnote).foregroundColor(.green)
                }
                if let loadFailure {
                    Text(loadFailure).font(.footnote).foregroundColor(.red)
                }
            } footer: {
                Text("Anything else in the file — comments included — is left exactly as it is; only these two lists are rewritten.")
            }
        }
        .navigationTitle("Injection filter")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        guard let text = FS.read(path) else {
            loadFailure = "There is no \(project.name).plist in this project. A tweak needs one: its file name has to match TWEAK_NAME."
            return
        }
        filter = InjectionFilter.parse(text)
    }

    private func save() {
        do {
            try FS.write(filter.serialized(), to: path)
            saved = "Saved."
            loadFailure = nil
            filter.raw = filter.serialized()
        } catch {
            loadFailure = "Could not write the filter: \(error.localizedDescription)"
        }
    }
}
