import SwiftUI

struct WorkspaceLayoutView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var volumeHandler = VolumeButtonHandler()
    @StateObject private var speechManager = SpeechInputManager()

    var body: some View {
        NavigationStack {
            Group {
                if appState.surfaces.isEmpty {
                    ContentUnavailableView(
                        "No surfaces",
                        systemImage: "square.split.2x1",
                        description: Text("Surfaces in the current workspace appear here.")
                    )
                } else {
                    surfaceGrid
                }
            }
            .navigationTitle("Layout")
            .background(Color.black.ignoresSafeArea())
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    workspacePills
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        statusDot
                        Button {
                            appState.refreshSurfaces()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .refreshable { appState.refreshSurfaces() }
        }
        .onAppear {
            appState.refreshSurfaces()
            speechManager.requestPermissions()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                setupVolumeHandler()
            }
        }
        .onDisappear {
            volumeHandler.stop()
        }
        .sheet(isPresented: $appState.isPairingPresented) {
            PairingView()
        }
    }

    // MARK: - Surface grid

    private var surfaceGrid: some View {
        let cols: [GridItem] = appState.surfaces.count == 1
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]

        return ScrollView {
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(appState.surfaces) { surface in
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
        .background(Color.black)
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
            }
        }
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

    // MARK: - Actions

    private func setupVolumeHandler() {
        let appState = appState
        let speech = speechManager

        volumeHandler.onSingleDown = {
            appState.cycleSurface()
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
