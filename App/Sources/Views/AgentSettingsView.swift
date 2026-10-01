import SwiftUI
import TheosStudioCore

/// Setting the assistant up.
///
/// The order matters and is the order of the screen: pick a provider (the
/// endpoint fills itself in), paste a key (kept in the keychain), then pick a
/// model from the provider's own list rather than typing a name from memory. The
/// test at the end is the same request the assistant makes, so a green result
/// means the next thing typed will work.
@MainActor
struct AgentSettingsView: View {

    @ObservedObject var store: StudioStore
    var onDone: () -> Void

    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var models: [AgentModel] = []
    @State private var isLoadingModels = false
    @State private var modelError: String?
    @State private var testResult: String?
    @State private var testSucceeded = false
    @State private var isTesting = false

    private var provider: AgentProvider { store.agent.provider }

    var body: some View {
        Form {
            providerSection
            credentialsSection
            modelSection
            testSection
            behaviourSection
            privacySection
        }
        .navigationTitle("Assistant setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    store.agent.rememberCurrent()
                    onDone()
                }
            }
        }
        .onAppear(perform: refreshKeyState)
    }

    // MARK: - Provider

    private var providerSection: some View {
        Section {
            Picker("Provider", selection: Binding(
                get: { store.agent.providerID },
                set: { newValue in
                    store.agent.select(AgentProvider.provider(id: newValue))
                    refreshKeyState()
                    models = []
                    modelError = nil
                    testResult = nil
                }
            )) {
                ForEach(AgentProvider.all) { candidate in
                    Text(candidate.displayName).tag(candidate.id)
                }
            }

            if let note = provider.note {
                Text(note).font(.footnote).foregroundColor(.secondary)
            }
            if let documentation = provider.documentation, let url = URL(string: documentation) {
                Link(destination: url) {
                    Label("Get an API key", systemImage: "arrow.up.right.square")
                }
                .font(.footnote)
            }
        } header: {
            Text("Provider")
        } footer: {
            Text("All of these speak the same protocol, so the assistant works with any of them. Local servers need no key at all.")
        }
    }

    // MARK: - Endpoint and key

    private var credentialsSection: some View {
        Section {
            TextField("Base URL", text: $store.agent.baseURL)
                .font(.system(size: 12, design: .monospaced))
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.URL)

            if provider.requiresKey {
                if hasKey {
                    HStack {
                        Label("Key stored for \(provider.displayName)", systemImage: "checkmark.seal.fill")
                            .font(.footnote)
                            .foregroundColor(.green)
                        Spacer()
                        Button("Replace") { AgentKeychain.delete(for: provider.id); hasKey = false }
                            .buttonStyle(.borderless)
                            .font(.footnote)
                    }
                } else {
                    SecureField("API key", text: $keyDraft)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Save key") {
                        AgentKeychain.save(keyDraft, for: provider.id)
                        keyDraft = ""
                        refreshKeyState()
                        modelError = nil
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Label("This endpoint does not need a key", systemImage: "lock.open")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Endpoint")
        } footer: {
            Text("The key is kept in the iOS keychain under this provider's name — switching providers does not overwrite it, and it is never written to the settings file. It is sent only to \(store.agent.host).")
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            HStack {
                Text("Model")
                Spacer()
                Text(store.agent.model.isEmpty ? "not chosen" : store.agent.model)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(store.agent.model.isEmpty ? .orange : .secondary)
                    .multilineTextAlignment(.trailing)
            }

            Button {
                loadModels()
            } label: {
                if isLoadingModels {
                    HStack { ProgressView().scaleEffect(0.7); Text("Asking \(store.agent.host)…") }
                } else {
                    Label("Load the model list", systemImage: "arrow.down.circle")
                }
            }
            .disabled(isLoadingModels || (provider.requiresKey && !hasKey))

            if !models.isEmpty {
                Picker("Choose", selection: Binding(
                    get: { store.agent.model },
                    set: { store.agent.model = $0; store.agent.rememberCurrent() }
                )) {
                    if store.agent.model.isEmpty {
                        Text("Pick a model").tag("")
                    }
                    ForEach(models) { model in
                        Text(model.title).tag(model.id)
                    }
                }
                Text("\(models.count) models can hold a conversation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !provider.suggestions.isEmpty && models.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested").font(.caption).foregroundColor(.secondary)
                    ForEach(provider.suggestions, id: \.self) { suggestion in
                        Button {
                            store.agent.model = suggestion
                            store.agent.rememberCurrent()
                        } label: {
                            HStack {
                                Text(suggestion).font(.system(size: 12, design: .monospaced))
                                Spacer()
                                if store.agent.model == suggestion {
                                    Image(systemName: "checkmark").foregroundColor(.green)
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            TextField("Model id (if you already know it)", text: Binding(
                get: { store.agent.model },
                set: { store.agent.model = $0; store.agent.rememberCurrent() }
            ))
            .font(.system(size: 12, design: .monospaced))
            .autocapitalization(.none)
            .disableAutocorrection(true)

            if let modelError {
                Text(modelError).font(.footnote).foregroundColor(.red)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Loading the list is one request to the provider. Without a key only the provider's own suggestions are offered, which is also what happens when a provider does not publish a list.")
        }
    }

    // MARK: - Test

    private var testSection: some View {
        Section {
            Button(action: test) {
                if isTesting {
                    HStack { ProgressView().scaleEffect(0.7); Text("Asking the model…") }
                } else {
                    Label(testSucceeded ? "Working — test again" : "Test the connection", systemImage: testSucceeded ? "checkmark.seal.fill" : "bolt.horizontal")
                }
            }
            .disabled(isTesting || !store.agent.isConfigured || (provider.requiresKey && !hasKey))

            if let testResult {
                Text(testResult)
                    .font(.footnote)
                    .foregroundColor(testSucceeded ? .green : .red)
            }
        } header: {
            Text("Test")
        } footer: {
            Text("Sends one short request: the same endpoint, key and model the assistant uses. Nothing about your project is included.")
        }
    }

    // MARK: - Behaviour

    private var behaviourSection: some View {
        Section {
            HStack {
                Text("Creativity")
                Slider(value: $store.agent.temperature, in: 0...1, step: 0.1)
                Text(String(format: "%.1f", store.agent.temperature))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Stepper(value: $store.agent.maxToolCallsPerTurn, in: 1...40) {
                Text("Tool calls per turn: \(store.agent.maxToolCallsPerTurn)")
            }
            TextEditor(text: $store.agent.extraInstructions)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 80)
        } header: {
            Text("Behaviour")
        } footer: {
            Text("A low temperature writes plainer code. The tool limit is what stops a model that keeps building without getting anywhere. Extra instructions are added as a second system message on every request.")
        }
    }

    private var privacySection: some View {
        Section {
            Text("Each request sends the project's text files (Makefile, control, Logos sources, plists and README), the last build's diagnostics, and the conversation so far. Nothing else on the device is read or sent, and the API key goes only to the endpoint above.")
                .font(.footnote)
                .foregroundColor(.secondary)
        } header: {
            Text("What is sent")
        }
    }

    // MARK: - Actions

    private func refreshKeyState() {
        hasKey = AgentKeychain.hasKey(for: provider.id)
        keyDraft = ""
    }

    private func loadModels() {
        isLoadingModels = true
        modelError = nil
        let settings = store.agent
        let key = AgentKeychain.load(for: settings.providerID) ?? ""
        Task {
            do {
                let listed = try await AgentClient().models(settings: settings, apiKey: key)
                models = listed
                if listed.isEmpty {
                    modelError = "The provider returned no chat models. Type the id if you know it."
                }
            } catch {
                models = []
                modelError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isLoadingModels = false
        }
    }

    private func test() {
        isTesting = true
        testResult = nil
        testSucceeded = false
        let settings = store.agent
        let key = AgentKeychain.load(for: settings.providerID) ?? ""
        Task {
            do {
                let reply = try await AgentClient().verify(settings: settings, apiKey: key)
                testSucceeded = true
                testResult = "\(settings.model) answered: \(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(90))"
            } catch {
                testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isTesting = false
        }
    }
}
