import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("autoSubmitSpeech") private var autoSubmitSpeech = true
    @AppStorage("volumeButtonControls") private var volumeButtonControls = false
    @AppStorage(MerryTheme.storageKey) private var themeID = MerryTheme.midnight.rawValue
    @State private var showUnpairConfirm = false
    @State private var renameTarget: SavedBridge?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Form {
                Group {
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
                        LabeledContent("Status", value: appState.connectionStatus.label(backend: appState.backendKind))
                        LabeledContent("Runtime", value: appState.backendKind)
                        remoteAccess(creds)
                    }
                }

                if appState.isComposite {
                    Section("Show workspaces from") {
                        Picker("Runtime", selection: $appState.runtimeFilter) {
                            ForEach(RuntimeFilter.allCases) { filter in
                                Text(filter.label).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("This bridge fronts both cmux and herdr. Pick one to see only its workspaces, or All to see both side by side. Also available from the sidebar menu.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Theme") {
                    ForEach(MerryTheme.allCases) { theme in
                        Button {
                            Theme.sync(theme.rawValue)
                            themeID = theme.rawValue
                        } label: {
                            HStack(spacing: 12) {
                                ThemeSwatch(palette: theme.palette)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(theme.name).font(.body).foregroundStyle(.primary)
                                    Text(theme.blurb).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if themeID == theme.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Theme.c.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(themeID == theme.rawValue ? .isSelected : [])
                    }
                }

                Section("Quick Actions") {
                    NavigationLink("Manage Quick Actions") {
                        QuickActionSettingsView()
                    }
                }

                Section("Walkie-Talkie") {
                    Toggle("Volume button controls", isOn: $volumeButtonControls)
                    Text("When enabled, the hardware volume buttons stop changing volume and drive the app instead: volume up starts or sends a dictation, double-tap up opens quick actions, volume down cycles surfaces, double-tap down cycles workspaces.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                .listRowBackground(Theme.c.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.c.background)
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
        let reach = (c.tailscaleHost?.isEmpty == false) ? "remote" : "LAN only"
        // The active bridge reports its runtime live; others show what their
        // pairing URL said, if anything.
        let backend = bridge.id == appState.selectedBridgeID ? appState.backendKind : c.backend
        if let backend, !backend.isEmpty {
            return "\(c.host):\(c.port) · \(reach) · \(backend)"
        }
        return "\(c.host):\(c.port) · \(reach)"
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
            Text("This pairing is LAN-only, so the app can't connect off Wi-Fi. To enable remote access, run `merry-bridge --pair --tailscale` on your Mac and scan the new QR with “Pair new device”.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// A theme at a glance: its page with a message bubble and the send colour.
private struct ThemeSwatch: View {
    let palette: Palette

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(palette.background)
            .frame(width: 52, height: 40)
            .overlay(alignment: .topTrailing) {
                Capsule().fill(palette.bubble).frame(width: 24, height: 9).padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                Capsule().fill(palette.text.opacity(0.85)).frame(width: 20, height: 4).padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 3) {
                    Circle().fill(palette.attention).frame(width: 7, height: 7)
                    Circle().fill(palette.accent).frame(width: 11, height: 11)
                }
                .padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
