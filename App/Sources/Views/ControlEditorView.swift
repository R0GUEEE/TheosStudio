import SwiftUI
import TheosStudioCore

/// A form over the `control` file.
///
/// The file is the one artefact in a project that every package manager reads,
/// and it is also the one where a typo is invisible: `Depends: mobilesubstrate`
/// spelled wrong installs a tweak that never loads. So the same engine that
/// parses it for the project list validates it here, field by field, with a raw
/// editor a tap away for anything the form does not know about.
@MainActor
struct ControlEditorView: View {

    let path: String
    var kind: ProjectKind?
    var projectName: String?

    /// The fields the form shows in order. Anything else in the file is listed
    /// below them and kept intact.
    private let knownFields = [
        "Package", "Name", "Version", "Architecture", "Section",
        "Depends", "Maintainer", "Author", "Homepage", "Depiction", "Description",
    ]

    @State private var control = ControlFile()
    @State private var raw = ""
    @State private var isRawMode = false
    @State private var saved = ""
    @State private var newFieldName = ""
    @State private var isAddingField = false
    @State private var loadFailure: String?

    private var issues: [ValidationIssue] {
        ControlValidator.issues(for: control, kind: kind, projectName: projectName)
    }

    private var otherFields: [ControlField] {
        control.fields.filter { !knownFields.contains { $0.caseInsensitiveCompare($1.key) == .orderedSame } }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Edit as text", isOn: $isRawMode)
                    .onChange(of: isRawMode) { isRaw in
                        if isRaw {
                            raw = control.serialized()
                        } else {
                            control = ControlFile.parse(raw)
                        }
                    }
            } footer: {
                Text("The form keeps fields it does not know about, and writes them back in the order Debian expects.")
            }

            if isRawMode {
                Section {
                    TextEditor(text: $raw)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 320)
                } header: {
                    Text("control")
                }
            } else {
                Section {
                    ForEach(knownFields, id: \.self) { key in
                        HStack {
                            Text(key).font(.footnote).foregroundColor(.secondary).frame(width: 92, alignment: .leading)
                            TextField(key, text: binding(for: key))
                                .font(.system(size: 13, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                    }
                } header: {
                    Text("Fields")
                } footer: {
                    Text("Architecture is overwritten by Theos at package time from the packaging scheme. Version has to change for dpkg to accept an upgrade.")
                }

                Section {
                    ForEach(otherFields, id: \.key) { field in
                        HStack {
                            Text(field.key).font(.footnote).foregroundColor(.secondary).frame(width: 92, alignment: .leading)
                            TextField(field.key, text: binding(for: field.key))
                                .font(.system(size: 13, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                    }
                    Button {
                        isAddingField = true
                    } label: {
                        Label("Add field", systemImage: "plus")
                    }
                } header: {
                    Text("Other fields")
                }
            }

            if !issues.isEmpty {
                Section {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: issue.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(issue.severity == .error ? .red : .orange)
                            Text(issue.message).font(.footnote)
                        }
                    }
                } header: {
                    Text("Problems")
                }
            }

            if let loadFailure {
                Section { Text(loadFailure).foregroundColor(.red).font(.footnote) }
            }
        }
        .navigationTitle("control")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save", action: save).disabled(!isModified)
            }
        }
        .onAppear(perform: load)
        .alert("New field", isPresented: $isAddingField) {
            TextField("Field name", text: $newFieldName)
            Button("Add") {
                let key = ControlFile.canonicalKeyCase(newFieldName.trimmingCharacters(in: .whitespaces))
                if !key.isEmpty {
                    control[key] = control[key] ?? ""
                }
                newFieldName = ""
            }
            Button("Cancel", role: .cancel) { newFieldName = "" }
        } message: {
            Text("Debian field names are case-insensitive; the canonical spelling is used when the file is written.")
        }
    }

    private var isModified: Bool {
        currentText != saved
    }

    private var currentText: String {
        isRawMode ? raw : control.serialized()
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { control[key] ?? "" },
            set: { control[key] = $0.isEmpty ? nil : $0 }
        )
    }

    private func load() {
        guard let contents = FS.read(path) else {
            loadFailure = "Could not read \(path)."
            return
        }
        control = ControlFile.parse(contents)
        raw = contents
        saved = contents
    }

    private func save() {
        let text = currentText
        do {
            try FS.write(text, to: path)
            saved = text
            control = ControlFile.parse(text)
            raw = text
            loadFailure = nil
        } catch {
            loadFailure = "Could not save: \(error.localizedDescription)"
        }
    }
}
