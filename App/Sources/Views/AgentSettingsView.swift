import SwiftUI
import TheosStudioCore

/// Where the assistant's model comes from.
///
/// Bring your own: an OpenAI-compatible endpoint and a key. The app has no
/// account and no bundled model, and the key is kept in the keychain rather than
/// in the settings file.
@MainActor
struct AgentSettingsView: View {

    @ObservedObject var store: StudioStore
    var onDone: () -> Void

    @State private var keyDraft = ""
    @State private var hasKey = AgentKeychain.hasKey
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                TextField("Base URL", text: $store.agent.baseURL)
                    .font(.system(size: 12, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("Model", text: $store.agent.model)
                    .font(.system(size: 12, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } header: {
                Text("Endpoint")
            } footer: {
                Text("Any OpenAI-compatible /chat/completions endpoint: OpenAI, a gateway, or a machine on your network. The chat endpoint is appended for you.")
            }

            Section {
                if hasKey {
                    HStack {
                        Label("API key stored", systemImage: "checkmark.seal.fill").foregroundColor(.green)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            AgentKeychain.delete()
                            hasKey = false
                            testResult = nil
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    SecureField("API key", text: $keyDraft)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Save key") {
                        AgentKeychain.save(keyDraft)
                        keyDraft = ""
                        hasKey = AgentKeychain.hasKey
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Button {
                    test()
                } label: {
                    if isTesting {
                        HStack { ProgressView().scaleEffect(0.7); Text("Asking the model…") }
                    } else {
                        Label("Test connection", systemImage: "bolt.horizontal")
                    }
                }
                .disabled(isTesting || !hasKey || !store.agent.isConfigured)

                if let testResult {
                    Text(testResult).font(.footnote)
                }
            } header: {
                Text("Credentials")
            } footer: {
                Text("The key is stored in the iOS keychain, not in the app's settings file. It is sent only to the endpoint above.")
            }

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
            } header: {
                Text("Behaviour")
            } footer: {
                Text("A low temperature writes plainer code. The tool limit is what stops a model that keeps building without getting anywhere.")
            }

            Section {
                TextEditor(text: $store.agent.extraInstructions)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 90)
            } header: {
                Text("Extra instructions")
            } footer: {
                Text("Added as a second system message on every request: house style, a target iOS version, a naming convention.")
            }

            Section {
                Text("Each request sends the project's text files (the Makefile, control, the Logos sources and the plists), the last build's diagnostics, and the conversation so far. Nothing else on the device is read or sent.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } header: {
                Text("What is sent")
            }
        }
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done", action: onDone)
            }
        }
    }

    private func test() {
        isTesting = true
        testResult = nil
        let settings = store.agent
        let key = AgentKeychain.load() ?? ""
        Task {
            do {
                let reply = try await AgentClient().verify(settings: settings, apiKey: key)
                testResult = "The model answered: \(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))"
            } catch {
                testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isTesting = false
        }
    }
}
