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
