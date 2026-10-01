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
    @State private var keyStorage: AgentKeyStore.Storage = .missing
    @State private var keyLength = 0
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
            approvalsSection
            toolsSection
            instructionsSection
            behaviourSection
            contextSection
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
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Key stored for \(provider.displayName)", systemImage: keyStorage.isSecure ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundColor(keyStorage.isSecure ? .green : .orange)
                        Text("\(keyStorage.label) \(keyLength) characters.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Button("Replace key") {
                        AgentKeyStore.delete(for: provider.id)
                        refreshKeyState()
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                } else {
                    SecureField("API key", text: $keyDraft)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Save key") {
                        let storage = AgentKeyStore.save(keyDraft, for: provider.id)
                        keyDraft = ""
                        modelError = nil
                        refreshKeyState()
                        if storage == .missing {
                            modelError = "The key could not be stored: the keychain refused it and the app's own folder is not writable."
                        }
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

            if let caveat = AgentModelList.toolCallingCaveat(for: store.agent.model) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(caveat).font(.footnote)
                }
            }

            if let modelError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(modelError).font(.footnote).foregroundColor(.red)
                    Text("Requested: GET \(store.agent.modelsEndpoint?.absoluteString ?? "—")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("Key: \(hasKey ? "present, \(keyLength) characters" : "none")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button {
                        UIPasteboard.general.string = "GET \(store.agent.modelsEndpoint?.absoluteString ?? "?")\nkey: \(hasKey ? "\(keyLength) chars" : "missing")\nerror: \(modelError)"
                    } label: {
                        Label("Copy these details", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
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

    // MARK: - Approvals

    private var approvalsSection: some View {
        Section {
            Picker("Approval", selection: $store.agent.approvals) {
                ForEach(AgentApprovalPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Text(store.agent.approvals.summary).font(.footnote).foregroundColor(.secondary)

            if store.agent.approvals == .fullAuto {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Changes will be written without showing you a diff first. The transcript still records each one, and the rules that keep the agent inside the project still apply.")
                        .font(.footnote)
                }
            }
        } header: {
            Text("Approval")
        } footer: {
            Text("Whatever this is set to, the agent cannot write outside the project, touch build output, or read the device's files: those are rules, not preferences.")
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        Section {
            ForEach(AgentToolCatalog.all, id: \.name) { tool in
                Toggle(isOn: Binding(
                    get: { store.agent.enabledTools.contains(tool.name) },
                    set: { isOn in
                        if isOn {
                            store.agent.enabledTools.insert(tool.name)
                        } else {
                            store.agent.enabledTools.remove(tool.name)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.system(size: 13, design: .monospaced))
                        Text(shortDescription(tool))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            HStack {
                Button("All") { store.agent.enabledTools = AgentToolCatalog.names }
                    .buttonStyle(.borderless)
                Spacer()
                Button("None") { store.agent.enabledTools = [] }
                    .buttonStyle(.borderless)
            }
        } header: {
            Text("Tools (\(store.agent.enabledTools.count) of \(AgentToolCatalog.names.count))")
        } footer: {
            Text("A tool that is off is not offered to the model at all, and refused by name if it asks anyway. Turning off install and build leaves an assistant that can only read and edit.")
        }
    }

    private func shortDescription(_ tool: AgentTool) -> String {
        guard let period = tool.description.firstIndex(of: ".") else { return tool.description }
        return String(tool.description[tool.description.startIndex...period])
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        Section {
            ForEach(AgentPreference.allCases) { preference in
                Toggle(isOn: Binding(
                    get: { store.agent.preferences.contains(preference) },
                    set: { isOn in
                        if isOn {
                            store.agent.preferences.insert(preference)
                        } else {
                            store.agent.preferences.remove(preference)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preference.displayName)
                        Text(preference.summary)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("Standing instructions")
        } footer: {
            Text("Each of these is one line in the system prompt, written once rather than retyped. Anything else goes in the extra instructions below.")
        }
    }

    // MARK: - Context

    private var contextSection: some View {
        Section {
            Picker("What to send", selection: $store.agent.contextMode) {
                ForEach(AgentContextMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Text(store.agent.contextMode.summary).font(.footnote).foregroundColor(.secondary)

            Stepper(value: $store.agent.contextBudget, in: 4_000...200_000, step: 4_000) {
                Text("Project content per request: \(store.agent.contextBudget / 1000)k characters")
            }

            Stepper(value: $store.agent.maxTokens, in: 0...32_000, step: 1_024) {
                Text(store.agent.maxTokens == 0
                     ? "Max reply length: the provider's default"
                     : "Max reply length: \(store.agent.maxTokens) tokens")
            }
        } header: {
            Text("Context and length")
        } footer: {
            Text("A provider whose default reply length is small can cut a tool call off mid-argument, which looks like broken JSON. Setting a limit here is the fix.")
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
        keyDraft = ""
        let key = AgentKeyStore.load(for: provider.id)
        hasKey = key != nil
        keyLength = key?.count ?? 0
        keyStorage = AgentKeyStore.storage(for: provider.id)
    }

    private func loadModels() {
        isLoadingModels = true
        modelError = nil
        let settings = store.agent
        let key = AgentKeyStore.load(for: settings.providerID) ?? ""
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
        let key = AgentKeyStore.load(for: settings.providerID) ?? ""
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
