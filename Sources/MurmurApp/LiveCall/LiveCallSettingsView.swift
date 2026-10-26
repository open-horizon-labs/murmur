import MurmurCore
import SwiftUI

/// Settings > the notes key. The key lives in the Keychain (its own item); settings files never hold it.
struct LiveCallSettingsView: View {
    @State private var key = ""
    @State private var savedInKeychain = false
    @State private var message = ""

    private var keyEnvName: String { LiveSettings.load(root: LiveCallSetup.root).llm.keyEnv }
    private var environmentProvidesKey: Bool {
        !keyEnvName.isEmpty && !(ProcessInfo.processInfo.environment[keyEnvName] ?? "").isEmpty
    }

    var body: some View {
        Form {
            Section("Live call notes") {
                SecureField("Notes API key", text: $key)
                HStack {
                    Button("Save to Keychain") { save() }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove") { remove() }
                        .disabled(!savedInKeychain)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Used only when \(keyEnvName.isEmpty ? "the key variable" : keyEnvName) is not set in the environment or in the .env file next to your settings, and no key command is configured. Call text is sent to the notes service named on the Live Call screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .onAppear(perform: refresh)
    }

    private var statusText: String {
        if !message.isEmpty { return message }
        if environmentProvidesKey { return "\(keyEnvName) is set in the environment and takes precedence." }
        return savedInKeychain ? "A key is saved in the Keychain." : "No key saved."
    }

    private func refresh() {
        savedInKeychain = ((try? LiveCallSetup.notesKeychain.load()) ?? nil) != nil
    }

    private func save() {
        do {
            try LiveCallSetup.notesKeychain.save(key)
            key = ""
            message = "Saved to the Keychain."
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
        savedInKeychain = ((try? LiveCallSetup.notesKeychain.load()) ?? nil) != nil
    }

    private func remove() {
        do {
            try LiveCallSetup.notesKeychain.delete()
            message = "Removed from the Keychain."
        } catch {
            message = "Could not remove: \(error.localizedDescription)"
        }
        savedInKeychain = ((try? LiveCallSetup.notesKeychain.load()) ?? nil) != nil
    }
}
