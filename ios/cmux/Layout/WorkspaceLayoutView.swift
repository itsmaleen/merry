import SwiftUI

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

                canvas
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
        .onAppear {
            setupVolumeHandler()
            speechManager.requestPermissions()
            appState.refreshSurfaces()
            appState.refreshPanes()
        }
        .onDisappear {
            volumeHandler.stop()
        }
        .sheet(isPresented: $appState.isPairingPresented) {
            PairingView()
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvas: some View {
        if !appState.panes.isEmpty {
            spatialLayout
        } else if !appState.surfaces.isEmpty {
            surfaceGrid
        } else {
            emptyState
        }
    }

    // Spatial layout using geometry from pane.list
    private var spatialLayout: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(appState.panes) { pane in
                    let frame = scaledFrame(pane, in: geo.size)
                    PaneCardView(
                        title: appState.surfaceTitle(for: pane.focusedSurfaceID ?? ""),
                        isFocused: pane.isFocused,
                        hasNotification: appState.hasNotification(for: pane),
                        isTranscribing: speechManager.isRecording && pane.isFocused,
                        transcript: speechManager.transcript
                    )
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .onTapGesture { appState.focusPane(pane.id) }
                }
            }
        }
        .padding(12)
    }

    // Grid layout using surface.list (fallback when pane.list is unavailable)
    private var surfaceGrid: some View {
        let surfaces = appState.surfaces
        let columns: [GridItem] = surfaces.count == 1
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]

        return ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(surfaces) { surface in
                    PaneCardView(
                        title: surface.title,
                        isFocused: surface.id == appState.focusedSurfaceID,
                        hasNotification: appState.hasNotification(for: surface),
                        isTranscribing: speechManager.isRecording && surface.id == appState.focusedSurfaceID,
                        transcript: speechManager.transcript
                    )
                    .aspectRatio(1.5, contentMode: .fit)
                    .onTapGesture { appState.focusSurface(surface.id) }
                }
            }
            .padding(12)
        }
    }

    private var emptyState: some View {
        let msg: String = {
            switch appState.connectionStatus {
            case .disconnected, .connecting, .reconnecting: return "Not connected"
            case .connected(false): return "cmux not running"
            case .connected(true): return "No surfaces"
            }
        }()
        return Text(msg)
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.3))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Workspace pills

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

                statusDot.padding(.leading, 4)
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
        return Circle().fill(color).frame(width: 7, height: 7)
    }

    // MARK: - Layout math

    private func scaledFrame(_ pane: Pane, in size: CGSize) -> CGRect {
        let n = pane.normalizedFrame
        let pad: CGFloat = 4
        let w = size.width - pad * 2
        let h = size.height - pad * 2
        return CGRect(x: pad + n.minX * w, y: pad + n.minY * h, width: n.width * w, height: n.height * h)
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
        let appState = appState
        let speech = speechManager

        volumeHandler.onSingleDown = {
            // Cycle surfaces (works today); if spatial panes are available, cycle panes instead
            if !appState.panes.isEmpty {
                appState.cyclePane()
            } else {
                appState.cycleSurface()
            }
        }
        volumeHandler.onDoubleDown = {
            appState.cycleTabInFocusedPane()
        }
        volumeHandler.onSpeechBegan = {
            Task { @MainActor in speech.start() }
        }
        volumeHandler.onSpeechEnded = {
            Task { @MainActor in
                let text = speech.stop()
                if !text.isEmpty, let surfaceID = appState.focusedSurfaceID {
                    appState.sendText(text, to: surfaceID)
                }
            }
        }
        volumeHandler.start()
    }
}
