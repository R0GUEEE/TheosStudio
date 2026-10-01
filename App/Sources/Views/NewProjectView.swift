import SwiftUI
import TheosStudioCore

@MainActor
struct NewProjectView: View {

    @ObservedObject var store: StudioStore
    @Binding var isPresented: Bool

    /// `nil` means "whatever this device is", which is the right answer unless
    /// the user is building for a different jailbreak than the one they are on.
    private enum SchemeChoice: String, CaseIterable, Identifiable {
        case automatic, rootful, rootless, roothide
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return "This device"
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

    @State private var kind: ProjectKind = .tweak
    @State private var name = "MyTweak"
    @State private var identifier = ""
    @State private var identifierWasEdited = false
    @State private var schemeChoice: SchemeChoice = .automatic
    @State private var injectionBundle = "com.apple.springboard"
    @State private var authorName = ""
    @State private var authorEmail = ""
    @State private var summary = "A Theos project built on device."
    @State private var minimumIOS = "15.0"
    @State private var lastError: String?
    @State private var cloneURL = ""
    @State private var isCloning = false
    @State private var cloneLog: [String] = []

    private var scheme: PackagingScheme {
        schemeChoice.scheme ?? store.jailbreak.scheme
    }

    private var sanitizedName: String { ProjectNaming.sanitize(name) }
    /// Follows the name until the user edits it by hand, after which it is theirs.
    private var effectiveIdentifier: String {
        if identifierWasEdited, !identifier.isEmpty {
            return identifier
        }
        return ProjectNaming.defaultPackageIdentifier(name: sanitizedName, namespace: store.settings.namespace)
    }

    private var filesToWrite: [TemplateFile] {
        ProjectTemplate.files(for: request)
    }

    private var request: TemplateRequest {
        TemplateRequest(
            name: sanitizedName,
            kind: kind,
            scheme: scheme,
            packageIdentifier: effectiveIdentifier,
            authorName: authorName.isEmpty ? store.settings.authorName : authorName,
            authorEmail: authorEmail.isEmpty ? store.settings.authorEmail : authorEmail,
            summary: summary,
            minimumIOSVersion: minimumIOS,
            injectionBundle: injectionBundle
        )
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("https://github.com/user/tweak.git", text: $cloneURL)
                        .font(.system(size: 12, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    Button {
                        clone()
                    } label: {
                        if isCloning {
                            HStack { ProgressView().scaleEffect(0.7); Text("Cloning…") }
                        } else {
                            Label("Clone it", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(isCloning || cloneURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !cloneLog.isEmpty {
                        ConsoleText(lines: cloneLog).frame(height: 140).cornerRadius(8)
                    }
                } header: {
                    Text("From a Git repository")
                } footer: {
                    Text("For starting from someone else's tweak, or your own. The repository is cloned with its submodules into the projects folder and opens with everything the app already knows, because a Theos project is just files.")
                }

                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(ProjectKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    Text(kind.summary)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("What to create")
                }

                Section {
                    TextField("Name", text: $name)
                        .autocapitalization(.words)
                        .disableAutocorrection(true)
                    TextField("Package identifier", text: Binding(
                        get: { effectiveIdentifier },
                        set: { identifier = $0; identifierWasEdited = true }
                    ))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                    TextField("One-line description", text: $summary)
                } header: {
                    Text("Identity")
                } footer: {
                    if !ProjectNaming.isValid(sanitizedName) {
                        Text("The name has to start with a capital letter and contain only letters and numbers — Theos uses it as a C identifier, a file name and a Theos variable.")
                            .foregroundColor(.red)
                    } else if !ControlValidator.isValidPackageIdentifier(effectiveIdentifier) {
                        Text("The identifier has to be lowercase, with dots separating the parts.")
                            .foregroundColor(.red)
                    } else {
                        Text("The folder will be \(store.settings.projectsDirectory.removingPrefix(NSHomeDirectory()))/\(sanitizedName), and the filter file \(sanitizedName).plist.")
                    }
                }

                Section {
                    Picker("Packaging", selection: $schemeChoice) {
                        ForEach(SchemeChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    if scheme == .roothide {
                        Text("roothide needs the roothide Theos fork, not upstream Theos. If that is not the Theos installed here, the build will fail with an unknown-scheme error.")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    } else {
                        Text(scheme.summary)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Text("Installs under \(scheme.installRootDescription), Architecture: \(scheme.debianArchitecture)")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                } header: {
                    Text("Packaging scheme")
                }

                if kind.usesInjectionFilter {
                    Section {
                        TextField("Bundle identifier", text: $injectionBundle)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(.body, design: .monospaced))
                    } header: {
                        Text("Injection target")
                    } footer: {
                        Text("Only this process loads the tweak. SpringBoard is the default; keeping the filter narrow is what keeps a tweak from draining the battery or crashing a daemon.")
                    }
                }

                Section {
                    TextField("Author", text: $authorName)
                    TextField("Email", text: $authorEmail)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.emailAddress)
                    TextField("Minimum iOS", text: $minimumIOS)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("Maintainer")
                }

                Section {
                    ForEach(filesToWrite, id: \.path) { file in
                        HStack {
                            Image(systemName: file.path.contains("/") ? "folder" : "doc.text")
                                .foregroundColor(.secondary)
                            Text(file.path)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Text("\(file.contents.utf8.count) B")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Will be created (\(filesToWrite.count) files)")
                }

                if let lastError {
                    Section {
                        Text(lastError).foregroundColor(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create", action: create).font(.body.weight(.semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            authorName = store.settings.authorName
            authorEmail = store.settings.authorEmail
        }
    }

    /// Cloning here rather than in a terminal because the interesting part is
    /// what happens after: the project is picked up by the same list, editor,
    /// build and assistant as anything created from a template.
    private func clone() {
        let url = cloneURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        guard let git = store.toolPaths(for: ["git"])["git"] else {
            lastError = "git is not installed on this device, so the app cannot clone anything."
            return
        }

        // The folder name comes from the URL, which is what everyone expects; a
        // URL ending in .git loses that suffix.
        var name = (url as NSString).lastPathComponent
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        name = ProjectNaming.sanitize(name)
        let destination = store.settings.projectsDirectory + "/" + name

        guard !FS.directoryExists(destination) else {
            lastError = "There is already something at \(destination). Pick another name by renaming the repository on disk first."
            return
        }

        isCloning = true
        cloneLog = ["$ git clone --recursive \(url) \(name)"]
        lastError = nil
        let process = ShellProcess(
            executable: git,
            arguments: ["clone", "--recursive", url, destination],
            environment: store.commandEnvironment()
        )
        do {
            try process.run(onLine: { line in
                cloneLog.append(line)
                if cloneLog.count > 400 { cloneLog.removeFirst() }
            }, onExit: { outcome in
                DispatchQueue.main.async {
                    isCloning = false
                    guard outcome.status == 0 else {
                        cloneLog.append("— exit \(outcome.status)")
                        lastError = "The clone failed. The output above is git's own; the usual causes are a private repository and no credentials on this device."
                        return
                    }
                    store.reloadProjects()
                    store.settings.lastProjectPath = destination
                    isPresented = false
                }
            })
        } catch {
            isCloning = false
            lastError = error.localizedDescription
        }
    }

    private func create() {
        do {
            let project = try store.createProject(request)
            store.settings.lastProjectPath = project.path
            isPresented = false
        } catch {
            lastError = error.localizedDescription
        }
    }
}
