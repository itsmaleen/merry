import SwiftUI
import MediaPlayer

struct WorkspaceLayoutView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var volumeHandler = VolumeButtonHandler()
    @StateObject private var speechManager = SpeechInputManager()
    @State private var showGear = false
    @State private var gearTimer: Timer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                workspacePills
                    .frame(height: 52)

                panesCanvas
            }

            if showGear {
                Button {
                    appState.isPairingPresented = true
                } label: {
                    Image(systemName: "gear")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(16)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showGear)
        .contentShape(Rectangle())
        .onTapGesture { revealGear() }
        .overlay(
            // Off-screen MPVolumeView suppresses system volume HUD
            VolumeHUDSuppressor(view: volumeHandler.volumeView)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false),
            alignment: .topLeading
        )
        .onAppear {
            setupVolumeHandler()
            speechManager.requestPermissions()
            appState.refreshPanes()
        }
        .onDisappear {
            volumeHandler.stop()
        }
        .sheet(isPresented: $appState.isPairingPresented) {
            PairingView()
        }
    }

    // MARK: - Subviews

    private var workspacePills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(appState.workspaces) { ws in
                    Button {
                        appState.selectWorkspace(ws.id)
                    } label: {
                        Text(ws.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ws.id == appState.currentWorkspaceID ? .black : .white.opacity(0.6))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(ws.id == appState.currentWorkspaceID
                                          ? Color.white
                                          : Color.white.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }

                // Connection status dot
                statusDot
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var statusDot: some View {
        let color: Color = {
            switch appState.connectionStatus {
            case .connected(true): return .green
            case .connected(false): return .yellow
            case .reconnecting, .connecting: return .yellow
            case .disconnected: return .red
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private var panesCanvas: some View {
        GeometryReader { geo in
            ZStack {
                if appState.panes.isEmpty {
                    emptyState(geo: geo)
                } else {
                    ForEach(appState.panes) { pane in
                        let frame = scaledFrame(pane, in: geo.size)
                        PaneCardView(
                            pane: pane,
                            surfaceTitle: appState.surfaceTitle(
                                for: pane.focusedSurfaceID ?? ""
                            ),
                            hasNotification: appState.hasNotification(for: pane),
                            isTranscribing: speechManager.isRecording && pane.isFocused,
                            transcript: speechManager.transcript
                        )
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .onTapGesture {
                            appState.focusPane(pane.id)
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func emptyState(geo: GeometryProxy) -> some View {
        let msg: String = {
            switch appState.connectionStatus {
            case .disconnected, .connecting, .reconnecting:
                return "Not connected"
            case .connected(false):
                return "cmux not running"
            case .connected(true):
                return "No panes"
            }
        }()
        Text(msg)
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.3))
            .frame(width: geo.size.width, height: geo.size.height)
    }

    // MARK: - Layout math

    private func scaledFrame(_ pane: Pane, in size: CGSize) -> CGRect {
        let n = pane.normalizedFrame
        let padding: CGFloat = 4
        let availW = size.width - padding * 2
        let availH = size.height - padding * 2
        return CGRect(
            x: padding + n.minX * availW,
            y: padding + n.minY * availH,
            width: n.width * availW,
            height: n.height * availH
        )
    }

    // MARK: - Actions

    private func revealGear() {
        showGear = true
        gearTimer?.invalidate()
        gearTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            withAnimation { showGear = false }
        }
    }

    private func setupVolumeHandler() {
        volumeHandler.onSingleDown = { [weak appState] in
            appState?.cyclePane()
        }
        volumeHandler.onDoubleDown = { [weak appState] in
            appState?.cycleTabInFocusedPane()
        }
        volumeHandler.onSpeechBegan = { [weak speechManager] in
            Task { @MainActor in speechManager?.start() }
        }
        volumeHandler.onSpeechEnded = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let text = self.speechManager.stop()
                if !text.isEmpty, let surfaceID = self.appState.focusedSurfaceID {
                    self.appState.sendText(text, to: surfaceID)
                }
            }
        }
        volumeHandler.start()
    }
}

// MARK: - MPVolumeView wrapper

struct VolumeHUDSuppressor: UIViewRepresentable {
    let view: MPVolumeView
    func makeUIView(context: Context) -> MPVolumeView { view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
