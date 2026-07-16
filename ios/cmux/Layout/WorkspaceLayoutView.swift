import SwiftUI
import AudioToolbox

// MARK: - Quick action model

struct QuickAction: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let section: String
    let action: () -> Void
}

enum QuickActionBuilder {
    @MainActor
    static func build(surfaceID sid: String, appState: AppState, store: QuickActionStore, onToggleFullscreen: @escaping () -> Void = {}) -> [QuickAction] {
        let builtIn: [QuickAction] = [
            QuickAction(label: "Enter", icon: "return", section: "Input") {
                appState.sendKey("enter", to: sid)
            },
            QuickAction(label: "Ctrl+C", icon: "xmark.circle", section: "Input") {
                appState.sendKey("ctrl+c", to: sid)
            },
            QuickAction(label: "Ctrl+D", icon: "eject", section: "Input") {
                appState.sendKey("ctrl+d", to: sid)
            },
            QuickAction(label: "Ctrl+Z", icon: "pause.circle", section: "Input") {
                appState.sendKey("ctrl+z", to: sid)
            },
            QuickAction(label: "Clear", icon: "trash", section: "Input") {
                appState.sendKey("ctrl+l", to: sid)
            },
            QuickAction(label: "Tab", icon: "arrow.right.to.line", section: "Input") {
                appState.sendKey("tab", to: sid)
            },
            QuickAction(label: "Escape", icon: "escape", section: "Input") {
                appState.sendKey("escape", to: sid)
            },
            QuickAction(label: "Up Arrow", icon: "arrow.up", section: "Input") {
                appState.sendKey("up", to: sid)
            },
            QuickAction(label: "Down Arrow", icon: "arrow.down", section: "Input") {
                appState.sendKey("down", to: sid)
            },
            QuickAction(label: "Split Right", icon: "rectangle.split.2x1", section: "Terminal") {
                appState.splitSurface(direction: "right", surfaceID: sid)
            },
            QuickAction(label: "Split Down", icon: "rectangle.split.1x2", section: "Terminal") {
                appState.splitSurface(direction: "down", surfaceID: sid)
            },
            QuickAction(label: "New Terminal", icon: "plus.rectangle", section: "Terminal") {
                appState.createSurface()
            },
            QuickAction(label: "Close Surface", icon: "xmark.rectangle", section: "Terminal") {
                appState.closeSurface(sid)
            },
            QuickAction(label: "Zoom", icon: "arrow.up.left.and.arrow.down.right", section: "Terminal") {
                appState.togglePaneZoom(sid)
            },
            QuickAction(label: "New Workspace", icon: "square.grid.2x2", section: "Workspace") {
                appState.createWorkspace()
            },
            QuickAction(label: "Fullscreen", icon: "rectangle.fill", section: "Workspace") {
                onToggleFullscreen()
            },
            QuickAction(label: "Close Workspace", icon: "xmark.square", section: "Workspace") {
                if let wsID = appState.currentWorkspaceID {
                    appState.closeWorkspace(wsID)
                }
            },
        ]

        // Filter out hidden built-in actions
        var result = builtIn.filter { !store.isBuiltInHidden($0.label) }

        // Append visible custom actions
        for custom in store.customActions where !custom.isHidden {
            result.append(QuickAction(label: custom.label, icon: custom.icon, section: custom.section) {
                appState.sendText(custom.command, to: sid)
            })
        }

        return result
    }
}

@MainActor
final class QuickActionState: ObservableObject {
    @Published var isOpen = false
    @Published var isFullscreen = false
    @Published var selectedIndex = 0
    @Published var currentSectionIndex = 0
    var actions: [QuickAction] = []

    private static let canonicalOrder = ["Input", "Terminal", "Workspace", "AI"]

    var sectionOrder: [String] {
        let present = Set(actions.map(\.section))
        return Self.canonicalOrder.filter { present.contains($0) }
    }

    var currentSection: String {
        let order = sectionOrder
        guard !order.isEmpty else { return "" }
        guard order.indices.contains(currentSectionIndex) else { return order[0] }
        return order[currentSectionIndex]
    }

    var currentSectionActions: [(Int, QuickAction)] {
        actions.enumerated().filter { $0.element.section == currentSection }.map { ($0.offset, $0.element) }
    }

    func open(with actions: [QuickAction]) {
        self.actions = actions
        currentSectionIndex = 0
        // Nothing to show if every section is hidden and there are no custom
        // actions — bail instead of subscripting an empty sectionOrder.
        guard let firstSection = sectionOrder.first else { return }
        selectedIndex = actions.firstIndex(where: { $0.section == firstSection }) ?? 0
        isOpen = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func dismiss() {
        isOpen = false
        actions = []
    }

    func cycle() {
        let sectionItems = currentSectionActions
        guard !sectionItems.isEmpty else { return }
        if let currentPos = sectionItems.firstIndex(where: { $0.0 == selectedIndex }) {
            let nextPos = (currentPos + 1) % sectionItems.count
            selectedIndex = sectionItems[nextPos].0
        } else {
            selectedIndex = sectionItems[0].0
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func nextSection() {
        let count = sectionOrder.count
        guard count > 0 else { return }
        currentSectionIndex = (currentSectionIndex + 1) % count
        // Select first item in new section
        if let first = currentSectionActions.first {
            selectedIndex = first.0
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func prevSection() {
        let count = sectionOrder.count
        guard count > 0 else { return }
        currentSectionIndex = (currentSectionIndex - 1 + count) % count
        if let first = currentSectionActions.first {
            selectedIndex = first.0
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func execute() {
        guard actions.indices.contains(selectedIndex) else { return }
        actions[selectedIndex].action()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismiss()
    }
}

struct WorkspaceLayoutView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var quickActionStore: QuickActionStore
    @AppStorage("autoSubmitSpeech") private var autoSubmitSpeech = true
    @StateObject private var volumeHandler = VolumeButtonHandler()
    @StateObject private var speechManager = SpeechInputManager()
    @StateObject private var quickAction = QuickActionState()
    @State private var lastNotificationCount = 0
    @State private var cycleDirection: Edge = .trailing
    @State private var isEditingTranscript = false
    @State private var editingText = ""
    @State private var contentPollTimer: Timer?
    // True while the remote-keyboard compose bar is focused; collapses the
    // layout to just the focused terminal so it owns the whole screen.
    @State private var keyboardActive = false

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

                // Always-available remote keyboard for the focused terminal.
                if !quickAction.isFullscreen, !quickAction.isOpen,
                   let sid = appState.focusedSurfaceID,
                   let surface = appState.surfaces.first(where: { $0.id == sid }),
                   !surface.isBrowser {
                    TerminalInputBar(
                        surfaceTitle: surface.title,
                        isActive: $keyboardActive,
                        onSendText: { appState.sendText($0, to: sid) },
                        onSendEnter: { appState.sendText($0 + "\n", to: sid) },
                        onSendKey: { appState.sendKey($0, to: sid) }
                    )
                    .padding(.bottom, 2)
                }

                if !quickAction.isFullscreen, !keyboardActive {
                    workspaceBar
                        .padding(.bottom, 4)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: keyboardActive)

            // Quick action overlay
            if quickAction.isOpen {
                quickActionOverlay
            }
        }
        .fullScreenCover(isPresented: $isEditingTranscript) {
            TranscriptEditorView(
                isPresented: $isEditingTranscript,
                text: editingText
            ) { finalText in
                if !finalText.isEmpty, let surfaceID = appState.focusedSurfaceID {
                    let toSend = autoSubmitSpeech ? finalText + "\n" : finalText
                    appState.sendText(toSend, to: surfaceID)
                }
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: quickAction.isOpen)
        .onChange(of: appState.notifications.count) { oldCount, newCount in
            if newCount > oldCount {
                AudioServicesPlaySystemSound(1007)
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                // Auto-clear notifications on focused surface after 3s
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    appState.clearNotificationsForFocusedSurface()
                }
            }
            lastNotificationCount = newCount
        }
        .onChange(of: appState.focusedSurfaceID) { _, _ in
            // Clear notifications for newly focused surface after a moment
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                appState.clearNotificationsForFocusedSurface()
            }
        }
        .onAppear {
            appState.refreshSurfaces()
            speechManager.requestPermissions()
            wireVolumeCallbacks()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                volumeHandler.start()
            }
            startContentPolling()
        }
        .onDisappear {
            contentPollTimer?.invalidate()
            contentPollTimer = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Restart volume handler — iOS can deactivate AVAudioSession
            // when backgrounded, interrupted, or idle, killing the KVO observer
            volumeHandler.start()
            appState.refreshSurfaces()
            // Content polling can be left dead after a background/tab switch
            // (the timer was invalidated but onAppear never re-fired). Restart
            // it here so terminal content resumes updating without a manual
            // navigation back into the view.
            startContentPolling()
        }
    }

    // MARK: - Quick actions

    private func openQuickActions() {
        guard let surface = focusedSurface else { return }
        quickAction.open(with: QuickActionBuilder.build(surfaceID: surface.id, appState: appState, store: quickActionStore, onToggleFullscreen: { [quickAction] in quickAction.isFullscreen.toggle() }))
    }

    private var quickActionOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { quickAction.dismiss() }
                .gesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if value.translation.width < -30 || value.translation.height < -30 {
                                    quickAction.nextSection()
                                } else if value.translation.width > 30 || value.translation.height > 30 {
                                    quickAction.prevSection()
                                }
                            }
                        }
                )

            VStack(spacing: 0) {
                // Section tabs
                HStack(spacing: 0) {
                    ForEach(Array(quickAction.sectionOrder.enumerated()), id: \.element) { idx, section in
                        let isActive = idx == quickAction.currentSectionIndex
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                quickAction.currentSectionIndex = idx
                                if let first = quickAction.currentSectionActions.first {
                                    quickAction.selectedIndex = first.0
                                }
                            }
                        } label: {
                            Text(section.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(isActive ? .white : .white.opacity(0.3))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .overlay(alignment: .bottom) {
                                    if isActive {
                                        Rectangle()
                                            .fill(Color.white)
                                            .frame(height: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)

                // Current section tiles
                let sectionItems = quickAction.currentSectionActions
                let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: min(sectionItems.count, 5))

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(sectionItems, id: \.0) { index, action in
                        let isSelected = index == quickAction.selectedIndex
                        Button {
                            quickAction.selectedIndex = index
                            quickAction.execute()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                appState.refreshSurfaces()
                            }
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: action.icon)
                                    .font(.system(size: 16))
                                Text(action.label)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected ? Color.white.opacity(0.2) : Color.white.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isSelected ? Color.white.opacity(0.4) : .clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .animation(.easeInOut(duration: 0.2), value: quickAction.currentSectionIndex)

                // Hints
                HStack(spacing: 16) {
                    hintLabel(key: "VOL-", label: "cycle")
                    hintLabel(key: "VOL+", label: "select")
                    hintLabel(key: "SWIPE", label: "section")
                    hintLabel(key: "2xDN", label: "close")
                }
                .foregroundStyle(.white.opacity(0.2))
                .padding(.bottom, 10)
            }
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
        }
        .transition(.opacity)
    }

    private func hintLabel(key: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 9, weight: .bold, design: .monospaced))
            Text(label).font(.system(size: 9, design: .monospaced))
        }
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
            // iPhones report .compact width in both orientations, so size class
            // can't tell us portrait vs landscape — compare the actual bounds.
            let isLandscape = geo.size.width > geo.size.height
            // While composing, hide the secondaries so the focused terminal
            // gets the full screen alongside the keyboard.
            let hasSecondary = secondarySurfaces.count > 0 && !quickAction.isFullscreen && !keyboardActive

            Group {
                if isLandscape {
                    landscapeLayout(size: geo.size, hasSecondary: hasSecondary)
                } else {
                    portraitLayout(size: geo.size, hasSecondary: hasSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    // Landscape: focused pane fills the left ~65%, secondaries stack in a
    // vertical scroll sidebar on the right.
    private func landscapeLayout(size: CGSize, hasSecondary: Bool) -> some View {
        let mainWidth = hasSecondary ? size.width * 0.65 : size.width
        let sideWidth = size.width * 0.35
        return HStack(spacing: 8) {
            if let surface = focusedSurface {
                focusedCard(for: surface, contentScale: 1.0)
                    .frame(width: mainWidth - (hasSecondary ? 4 : 16))
            }
            if hasSecondary {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(secondarySurfaces) { surface in
                            secondaryTile(for: surface)
                                .frame(height: tileHeight(for: secondarySurfaces.count, in: size.height))
                        }
                    }
                }
                .frame(width: sideWidth - 4)
            }
        }
    }

    // Portrait: focused pane fills the width up top, secondaries sit in a
    // horizontal scroll row below — each tile gets a usable width instead of
    // being crushed into a narrow side column.
    private func portraitLayout(size: CGSize, hasSecondary: Bool) -> some View {
        let rowHeight: CGFloat = hasSecondary ? max(110, size.height * 0.24) : 0
        let tileWidth = max(150, size.width * 0.44)
        return VStack(spacing: 8) {
            if let surface = focusedSurface {
                focusedCard(for: surface, contentScale: 1.25)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if hasSecondary {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(secondarySurfaces) { surface in
                            secondaryTile(for: surface)
                                .frame(width: tileWidth, height: rowHeight)
                        }
                    }
                }
                .frame(height: rowHeight)
            }
        }
    }

    // Focused surface card with its cycle/quick-action gestures.
    private func focusedCard(for surface: Surface, contentScale: CGFloat) -> some View {
        PaneCardView(
            title: surface.title,
            isFocused: true,
            hasNotification: appState.hasNotification(for: surface),
            isTranscribing: speechManager.isRecording,
            transcript: speechManager.transcript,
            terminalText: surface.isBrowser ? "" : (appState.surfaceContent[surface.id] ?? ""),
            contentScale: contentScale,
            isBrowser: surface.isBrowser,
            browserURL: appState.browserURLs[surface.id] ?? "",
        )
        .id(surface.id)
        .transition(.asymmetric(
            insertion: .move(edge: cycleDirection).combined(with: .opacity),
            removal: .move(edge: cycleDirection == .trailing ? .leading : .trailing).combined(with: .opacity)
        ))
        .onLongPressGesture(minimumDuration: 0.4) {
            openQuickActions()
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 50)
                .onEnded { value in
                    guard !quickAction.isOpen else { return }
                    if speechManager.isRecording {
                        // Swipe while recording opens transcript editor
                        editingText = speechManager.stop()
                        volumeHandler.clearSpeechState()
                        isEditingTranscript = true
                        return
                    }
                    if value.translation.width < -50 {
                        cycleDirection = .trailing
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            appState.cycleSurface()
                        }
                    } else if value.translation.width > 50 {
                        cycleDirection = .leading
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            appState.cycleSurfaceBackward()
                        }
                    }
                },
            including: .gesture
        )
    }

    // Non-focused surface tile; tap or swipe to focus it.
    private func secondaryTile(for surface: Surface) -> some View {
        PaneCardView(
            title: surface.title,
            isFocused: false,
            hasNotification: appState.hasNotification(for: surface),
            isTranscribing: false,
            transcript: "",
            terminalText: surface.isBrowser ? "" : (appState.surfaceContent[surface.id] ?? ""),
            isBrowser: surface.isBrowser,
            browserURL: appState.browserURLs[surface.id] ?? ""
        )
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

    private func tileHeight(for count: Int, in totalHeight: CGFloat) -> CGFloat {
        let available = totalHeight - 52
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
            statusDot
                .padding(.leading, 16)
                .padding(.trailing, 12)

            workspacePills

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
        appState.notifications.contains { $0.workspaceID == ws.id }
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

    // MARK: - Content polling

    @State private var pollCycleCount = 0

    private func startContentPolling() {
        // Tear down any existing timer first — onAppear/foreground can fire more
        // than once, and a duplicate timer means double polling and wasted RPCs.
        contentPollTimer?.invalidate()
        contentPollTimer = nil
        // Initial fetch — focused only
        if let focused = focusedSurface {
            fetchContent(for: focused)
        }
        contentPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak appState] _ in
            Task { @MainActor in
                guard let appState else { return }
                self.pollCycleCount += 1
                let focusedID = appState.focusedSurfaceID
                // Focused surface every cycle, secondary every 5th (~15s)
                for surface in appState.surfaces {
                    if surface.id == focusedID {
                        self.fetchContent(for: surface)
                    } else if self.pollCycleCount % 5 == 0 {
                        self.fetchContent(for: surface)
                    }
                }
            }
        }
    }

    private func fetchContent(for surface: Surface) {
        if surface.isBrowser {
            appState.readBrowserURL(surface.id)
            return
        }
        let focused = surface.id == appState.focusedSurfaceID
        if appState.isKnownNonClaudeSurface(surface.id) {
            // Terminal surface: deep read when focused (scrollback), cheap preview otherwise.
            appState.readSurfaceText(surface.id, lines: focused ? AppState.focusedHistoryLines : 50)
        } else if focused {
            if appState.isKnownClaudeSurface(surface.id) {
                // Transcript pulls can be large; refresh every 3rd cycle (~9s).
                // Focus change already triggers an immediate fetch.
                if pollCycleCount % 3 == 0 {
                    appState.readClaudeTranscript(surface.id, fallbackLines: AppState.focusedHistoryLines)
                }
            } else {
                // Not yet classified — probe (classifies + falls back if needed).
                appState.readClaudeTranscript(surface.id, fallbackLines: AppState.focusedHistoryLines)
            }
        } else {
            // Background, not yet known to be claude: cheap viewport preview.
            appState.readSurfaceText(surface.id, lines: 50)
        }
    }

    // MARK: - Volume callbacks

    private func wireVolumeCallbacks() {
        let appState = appState
        let speech = speechManager
        let qa = quickAction
        let store = quickActionStore

        let volHandler = volumeHandler
        volumeHandler.onSingleDown = {
            print("[VolumeHandler] singleDown")
            Task { @MainActor in
                if speech.isRecording {
                    speech.cancel()
                    volHandler.clearSpeechState()
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                } else if qa.isOpen {
                    qa.cycle()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        appState.cycleSurface()
                    }
                }
            }
        }
        volumeHandler.onDoubleDown = {
            print("[VolumeHandler] doubleDown")
            Task { @MainActor in
                if qa.isOpen {
                    qa.dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        appState.cycleWorkspace()
                    }
                }
            }
        }
        volumeHandler.onSingleUp = {
            print("[VolumeHandler] singleUp")
            Task { @MainActor in
                if qa.isOpen {
                    // Confirm selected action
                    qa.execute()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        appState.refreshSurfaces()
                    }
                } else if speech.isRecording {
                    // Stop recording and send
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
                } else {
                    // Start recording
                    speech.start()
                }
            }
        }
        volumeHandler.onDoubleUp = {
            print("[VolumeHandler] doubleUp → quickActions")
            Task { @MainActor in
                if qa.isOpen {
                    qa.dismiss()
                } else if let surface = appState.surfaces.first(where: { $0.id == appState.focusedSurfaceID })
                            ?? appState.surfaces.first {
                    let sid = surface.id
                    qa.open(with: QuickActionBuilder.build(surfaceID: sid, appState: appState, store: store, onToggleFullscreen: { qa.isFullscreen.toggle() }))
                }
            }
        }
    }
}
