import SwiftUI

struct WorkspaceLayoutView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var volumeHandler = VolumeButtonHandler()
    @StateObject private var speechManager = SpeechInputManager()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                workspacePills
                    .padding(.vertical, 8)

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
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.black.ignoresSafeArea())
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
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
            wireVolumeCallbacks()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                volumeHandler.start()
            }
        }
        .onDisappear {
            // Don't stop the handler on tab switch — TabView triggers
            // onDisappear/onAppear on every tab change, which kills the
            // AVAudioSession observer and the MPVolumeView attachment.
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

    private func workspaceLabel(for ws: Workspace, at index: Int) -> String {
        let name = ws.name
        // If the name looks like a raw ID (e.g. hex hash), use a friendly label
        if name == ws.id || name.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            return "Workspace \(index + 1)"
        }
        return name
    }

    private var workspacePills: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(appState.workspaces.enumerated()), id: \.element.id) { index, ws in
                        Button {
                            appState.selectWorkspace(ws.id)
                        } label: {
                            Text(workspaceLabel(for: ws, at: index))
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
                        .id(ws.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: appState.currentWorkspaceID) { _, newID in
                if let id = newID {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
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

    private func wireVolumeCallbacks() {
        let appState = appState
        let speech = speechManager

        volumeHandler.onSingleDown = {
            print("[VolumeHandler] singleDown → cycleSurface")
            appState.cycleSurface()
        }
        volumeHandler.onDoubleDown = {
            print("[VolumeHandler] doubleDown → cycleWorkspace")
            appState.cycleWorkspace()
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
    }
}
