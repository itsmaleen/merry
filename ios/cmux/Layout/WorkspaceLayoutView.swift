import SwiftUI
import AudioToolbox

struct WorkspaceLayoutView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("autoSubmitSpeech") private var autoSubmitSpeech = true
    @StateObject private var volumeHandler = VolumeButtonHandler()
    @StateObject private var speechManager = SpeechInputManager()
    @State private var lastNotificationCount = 0
    @State private var cycleDirection: Edge = .trailing

    var body: some View {
        ZStack {
            // Background with subtle center glow
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [Color.white.opacity(0.03), Color.clear],
                center: .center,
                startRadius: 50,
                endRadius: 400
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                if appState.surfaces.isEmpty {
                    emptyState
                } else {
                    surfaceLayout
                }

                workspaceBar
                    .padding(.bottom, 4)
            }
        }
        .onChange(of: appState.notifications.count) { oldCount, newCount in
            if newCount > oldCount {
                AudioServicesPlaySystemSound(1007)
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
            lastNotificationCount = newCount
        }
        .onAppear {
            appState.refreshSurfaces()
            speechManager.requestPermissions()
            wireVolumeCallbacks()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                volumeHandler.start()
            }
        }
        .onDisappear {}
    }

    // MARK: - Surface layout

    private var focusedSurface: Surface? {
        appState.surfaces.first(where: { $0.id == appState.focusedSurfaceID })
            ?? appState.surfaces.first
    }

    private var secondarySurfaces: [Surface] {
        guard let focused = focusedSurface else { return [] }
        return appState.surfaces.filter { $0.id != focused.id }
    }

    private var surfaceLayout: some View {
        GeometryReader { geo in
            let hasSidebar = secondarySurfaces.count > 0
            let mainWidth = hasSidebar ? geo.size.width * 0.65 : geo.size.width
            let sideWidth = geo.size.width * 0.35

            HStack(spacing: 8) {
                // Focused surface — large card
                if let surface = focusedSurface {
                    PaneCardView(
                        title: surface.title,
                        isFocused: true,
                        hasNotification: appState.hasNotification(for: surface),
                        isTranscribing: speechManager.isRecording,
                        transcript: speechManager.transcript
                    )
                    .id(surface.id)
                    .frame(width: mainWidth - (hasSidebar ? 4 : 16))
                    .transition(.asymmetric(
                        insertion: .move(edge: cycleDirection).combined(with: .opacity),
                        removal: .move(edge: cycleDirection == .trailing ? .leading : .trailing).combined(with: .opacity)
                    ))
                    .gesture(
                        DragGesture(minimumDistance: 40)
                            .onEnded { value in
                                if value.translation.width < -40 {
                                    cycleDirection = .trailing
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        appState.cycleSurface()
                                    }
                                } else if value.translation.width > 40 {
                                    cycleDirection = .leading
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        appState.cycleSurfaceBackward()
                                    }
                                }
                            }
                    )
                }

                // Secondary tiles
                if hasSidebar {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 6) {
                            ForEach(secondarySurfaces) { surface in
                                PaneCardView(
                                    title: surface.title,
                                    isFocused: false,
                                    hasNotification: appState.hasNotification(for: surface),
                                    isTranscribing: false,
                                    transcript: ""
                                )
                                .frame(height: tileHeight(for: secondarySurfaces.count, in: geo.size.height))
                                .onTapGesture {
                                    cycleDirection = .trailing
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        appState.focusSurface(surface.id)
                                    }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 30)
                                        .onEnded { value in
                                            if value.translation.height < -30 {
                                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                                    appState.focusSurface(surface.id)
                                                }
                                            }
                                        }
                                )
                            }
                        }
                    }
                    .frame(width: sideWidth - 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private func tileHeight(for count: Int, in totalHeight: CGFloat) -> CGFloat {
        let available = totalHeight - 52 // leave room for workspace bar
        let spacing = CGFloat(max(0, count - 1)) * 6
        return max(60, (available - spacing) / CGFloat(count))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.split.2x1")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(.white.opacity(0.2))
            Text("No surfaces")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Workspace bar

    private var workspaceBar: some View {
        HStack(spacing: 0) {
            // Status dot
            statusDot
                .padding(.leading, 16)
                .padding(.trailing, 12)

            // Workspace pills (centered)
            workspacePills

            // Speech indicator + refresh
            HStack(spacing: 10) {
                if speechManager.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .shadow(color: .red.opacity(0.6), radius: 4)
                    Text("REC")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red)
                }

                Button {
                    appState.refreshSurfaces()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.trailing, 16)
            .padding(.leading, 12)
        }
        .frame(height: 36)
    }

    // MARK: - Workspace pills

    private func workspaceLabel(for ws: Workspace, at index: Int) -> String {
        let name = ws.name
        if name == ws.id || name.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            return "Workspace \(index + 1)"
        }
        return name
    }

    private func workspaceHasNotification(_ ws: Workspace) -> Bool {
        guard ws.id == appState.currentWorkspaceID else { return false }
        let surfaceIDs = Set(appState.surfaces.map(\.id))
        return appState.notifications.contains { n in
            guard let panelID = n.panelID else { return false }
            return surfaceIDs.contains(panelID)
        }
    }

    private var workspacePills: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(appState.workspaces.enumerated()), id: \.element.id) { index, ws in
                        let isActive = ws.id == appState.currentWorkspaceID
                        let hasNotif = workspaceHasNotification(ws)

                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                appState.selectWorkspace(ws.id)
                            }
                        } label: {
                            Text(workspaceLabel(for: ws, at: index))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(isActive ? .black : .white.opacity(0.5))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(isActive ? Color.white : Color.white.opacity(0.08))
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(Color.orange, lineWidth: hasNotif ? 1.5 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .id(ws.id)
                    }
                }
                .padding(.horizontal, 8)
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
        return Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.5), radius: 3)
    }

    // MARK: - Actions

    private func wireVolumeCallbacks() {
        let appState = appState
        let speech = speechManager

        volumeHandler.onSingleDown = {
            print("[VolumeHandler] singleDown → cycleSurface")
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                appState.cycleSurface()
            }
        }
        volumeHandler.onDoubleDown = {
            print("[VolumeHandler] doubleDown → cycleWorkspace")
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                appState.cycleWorkspace()
            }
        }
        volumeHandler.onSpeechBegan = {
            Task { @MainActor in speech.start() }
        }
        volumeHandler.onSpeechEnded = {
            Task { @MainActor in
                let pending = speech.transcript
                try? await Task.sleep(nanoseconds: 300_000_000)
                let text = speech.stop()
                let finalText = text.isEmpty ? pending : text
                print("[Speech] sending: \(finalText)")
                if !finalText.isEmpty, let surfaceID = appState.focusedSurfaceID {
                    let autoSubmit = UserDefaults.standard.bool(forKey: "autoSubmitSpeech")
                    let toSend = autoSubmit ? finalText + "\n" : finalText
                    appState.sendText(toSend, to: surfaceID)
                }
            }
        }
    }
}
