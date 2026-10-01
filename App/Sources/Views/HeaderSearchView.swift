import SwiftUI
import TheosStudioCore

/// Finding something to hook.
///
/// The workflow this exists for: you want to change how something looks or
/// behaves, you have a guess at the class name, and a `%hook` for a wrong guess
/// silently does nothing. Searching the headers turns the guess into a fact, and
/// the result carries the skeleton so the next step is one tap.
@MainActor
struct HeaderSearchView: View {

    @ObservedObject var store: StudioStore
    let project: Project?

    @StateObject private var indexer = HeaderIndexer()
    @State private var query = ""
    @State private var scope: HeaderIndexer.Source = .sdk
    @State private var selected: HeaderDeclaration?

    private var results: [HeaderDeclaration] {
        indexer.search(query)
    }

    private var customRoots: [String] {
        store.settings.headerSearchFolders.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        List {
            Section {
                Picker("Source", selection: $scope) {
                    ForEach(HeaderIndexer.Source.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: scope) { _ in startIndexing() }

                if scope == .custom {
                    ForEach(customRoots, id: \.self) { root in
                        Text(root)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if customRoots.isEmpty {
                        Text("Add a folder in Settings → Assistant → Header search. A dump of the headers you want to search is the most useful thing you can give this screen.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    if indexer.isIndexing {
                        ProgressView().scaleEffect(0.7)
                        Text("Reading headers…").font(.footnote).foregroundColor(.secondary)
                    } else {
                        Text("\(indexer.indexedFiles) headers read, \(indexer.declarations.count) declarations")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        startIndexing()
                    } label: {
                        Label("Index", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(indexer.isIndexing)
                }

                if let message = indexer.message {
                    Text(message).font(.footnote).foregroundColor(.secondary)
                }
            } header: {
                Text("Headers")
            }

            if query.isEmpty {
                Section {
                    Text("Type a class or method name. Searching a class also returns its methods, which is usually what you want next.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if results.isEmpty {
                Section {
                    Text(indexer.declarations.isEmpty
                         ? "Nothing has been indexed yet."
                         : "No declaration matches “\(query)”.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    ForEach(results) { declaration in
                        Button {
                            selected = declaration
                        } label: {
                            DeclarationRow(declaration: declaration)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("\(results.count) match\(results.count == 1 ? "" : "es")")
                } footer: {
                    Text("A class or protocol can be hooked. A method is what goes inside the hook — search its class name for that.")
                }
            }
        }
        .searchable(text: $query)
        .listStyle(.insetGrouped)
        .navigationTitle("Find a hook")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if indexer.declarations.isEmpty { startIndexing() }
        }
        .sheet(item: $selected) { declaration in
            NavigationView {
                DeclarationDetailView(
                    declaration: declaration,
                    project: project,
                    onCreated: { outcome in
                        store.banner = BannerMessage(
                            title: outcome.warnings.isEmpty ? "File created" : "File created, with a note",
                            body: (outcome.notes + outcome.warnings).joined(separator: "\n\n")
                        )
                    }
                )
            }
            .navigationViewStyle(.stack)
        }
    }

    private func startIndexing() {
        let roots: [String]
        switch scope {
        case .sdk:
            roots = HeaderIndexer.sdkRoots(theosRoot: store.toolchain?.theosRoot)
        case .custom:
            roots = customRoots
        }
        indexer.index(roots: roots)
    }
}

private struct DeclarationRow: View {
    let declaration: HeaderDeclaration

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StatusChip(text: declaration.kind.label, color: declaration.hookable ? .blue : .secondary)
                Text(declaration.name)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text(declaration.location)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if let owner = declaration.owner, declaration.kind != .interface {
                Text(owner).font(.caption2).foregroundColor(.secondary)
            }
            Text(declaration.signature)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

private struct DeclarationDetailView: View {

    let declaration: HeaderDeclaration
    let project: Project?
    var onCreated: (ProjectFileEditor.Outcome) -> Void

    @Environment(\.presentationMode) private var presentation
    @State private var isCreating = false
    @State private var failure: String?

    private var skeleton: String? {
        HeaderIndex.hookSkeleton(for: declaration, projectName: project?.name ?? "MyTweak")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    StatusChip(text: declaration.kind.label, color: declaration.hookable ? .blue : .secondary)
                    if let owner = declaration.owner {
                        Text(owner).font(.footnote).foregroundColor(.secondary)
                    }
                }

                Text(declaration.signature)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)

                Text(declaration.file)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if let skeleton {
                    Text("Hook skeleton").font(.subheadline.weight(.medium))
                    Text(skeleton)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button {
                        UIPasteboard.general.string = skeleton
                    } label: {
                        Label("Copy the skeleton", systemImage: "doc.on.doc")
                    }

                    if project != nil {
                        Button {
                            isCreating = true
                        } label: {
                            Label("Create a file with it", systemImage: "doc.badge.plus")
                        }
                    }
                } else {
                    Text("This is a method, not a class. To hook it, search for its class — the hook block names the class, and the method goes inside it.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                if let failure {
                    Text(failure).font(.footnote).foregroundColor(.red)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(declaration.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { presentation.wrappedValue.dismiss() }
            }
        }
        .alert("Create \(declaration.name).x?", isPresented: $isCreating) {
            Button("Create") { create() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file is created in the project with the hook skeleton in it, and added to the Makefile's file list.")
        }
    }

    private func create() {
        guard let project, let skeleton else { return }
        do {
            let outcome = try ProjectFileEditor.create(
                project: project.path,
                path: "\(declaration.name).x",
                contents: skeleton,
                addToMakefile: true
            )
            onCreated(outcome)
            presentation.wrappedValue.dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
