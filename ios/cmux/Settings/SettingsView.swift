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

                        // Remote-access clarity: a pairing without a tailnet host
                        // only works on the same Wi-Fi and otherwise sits on
                        // "reconnecting". Make that state obvious and actionable.
                        if let ts = creds.tailscaleHost, !ts.isEmpty {
                            LabeledContent {
                                Label("On", systemImage: "checkmark.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.green)
                            } label: {
                                Text("Remote access")
                            }
                            Text("Tailnet: \(ts)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            LabeledContent {
                                Label("Off", systemImage: "exclamationmark.triangle.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.orange)
                            } label: {
                                Text("Remote access")
                            }
                            Text("This pairing is LAN-only, so the app can't connect off Wi-Fi. To enable remote access, run `cmux-bridge --pair --tailscale` on your Mac and scan the new QR with “Pair new device”.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Quick Actions") {
                    NavigationLink("Manage Quick Actions") {
                        QuickActionSettingsView()
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
