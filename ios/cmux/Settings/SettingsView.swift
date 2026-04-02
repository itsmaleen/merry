import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("autoSubmitSpeech") private var autoSubmitSpeech = true
    @State private var showUnpairConfirm = false
    @State private var credentials: PairingCredentials? = try? PairingStore().load()

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Status", value: appState.connectionStatus.label)

                    if let creds = credentials {
                        LabeledContent("Host", value: creds.host)
                        LabeledContent("Port", value: "\(creds.port)")
                    }
                }

                Section("Speech Input") {
                    Toggle("Auto-submit speech", isOn: $autoSubmitSpeech)
                    Text("When enabled, automatically presses Enter after sending speech text.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Pair new device") {
                        appState.isPairingPresented = true
                    }

                    Button("Unpair", role: .destructive) {
                        showUnpairConfirm = true
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                credentials = try? PairingStore().load()
            }
            .confirmationDialog(
                "Unpair this device?",
                isPresented: $showUnpairConfirm,
                titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) {
                    appState.unpair()
                    credentials = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will need to scan the QR code again to reconnect.")
            }
        }
    }
}
