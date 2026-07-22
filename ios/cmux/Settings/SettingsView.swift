import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("autoSubmitSpeech") private var autoSubmitSpeech = true
    @State private var showUnpairConfirm = false
    @State private var renameTarget: SavedBridge?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Bridges") {
                    ForEach(appState.bridges) { bridge in
                        bridgeRow(bridge)
                    }
                    Button("Pair new device") {
                        appState.isPairingPresented = true
                    }
                }

                if let creds = appState.selectedBridge?.credentials {
                    Section("Connection") {
                        LabeledContent("Status", value: appState.connectionStatus.label)
                        remoteAccess(creds)
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

                if !appState.bridges.isEmpty {
                    Section {
                        Button("Unpair all", role: .destructive) {
                            showUnpairConfirm = true
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Unpair all devices?",
                isPresented: $showUnpairConfirm,
                titleVisibility: .visible
            ) {
                Button("Unpair all", role: .destructive) {
                    appState.unpairAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will need to scan each QR code again to reconnect.")
            }
            .alert("Rename bridge", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let target = renameTarget {
                        appState.renameBridge(target.id, to: renameText)
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func bridgeRow(_ bridge: SavedBridge) -> some View {
        let isActive = bridge.id == appState.selectedBridgeID
        Button {
            appState.selectBridge(bridge.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bridge.name)
                        .foregroundStyle(.primary)
                    Text(bridgeSubtitle(bridge))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Text(appState.connectionStatus.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                appState.removeBridge(bridge.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            Button {
                renameText = bridge.name
                renameTarget = bridge
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    private func bridgeSubtitle(_ bridge: SavedBridge) -> String {
        let c = bridge.credentials
        if let ts = c.tailscaleHost, !ts.isEmpty {
            return "\(c.host):\(c.port) · remote"
        }
        return "\(c.host):\(c.port) · LAN only"
    }

    // MARK: - Remote-access explainer for the active bridge

    @ViewBuilder
    private func remoteAccess(_ creds: PairingCredentials) -> some View {
        // Remote-access clarity: a pairing without a tailnet host only works on
        // the same Wi-Fi and otherwise sits on "reconnecting". Make that state
        // obvious and actionable.
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
