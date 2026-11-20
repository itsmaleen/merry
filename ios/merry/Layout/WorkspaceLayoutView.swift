import SwiftUI
import AudioToolbox
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Quick action model

struct QuickAction: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let section: String
    let action: () -> Void
}

enum QuickActionBuilder {
    /// The default command for "New YOLO Tab": the user's own "Claude YOLO"
    /// action if they edited it, else the stock one.
    @MainActor
    static func yoloCommand(_ store: QuickActionStore) -> String {
        store.customActions.first(where: { $0.label == "Claude YOLO" })?.command
            ?? "claude --dangerously-skip-permissions\n"
    }

    /// Every visible action, each wrapped to count its use. With
    /// `includeTop`, the four most-used actions (run at least twice) are
    /// repeated in a leading "Top" section of the full menu.
    @MainActor
    static func build(surfaceID sid: String, appState: AppState, store: QuickActionStore, includeTop: Bool = false, onToggleFullscreen: @escaping () -> Void = {}, onOpenSearch: @escaping () -> Void = {}) -> [QuickAction] {
        var builtIn: [QuickAction] = [
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
            QuickAction(label: "Add File", icon: "paperclip", section: "Input") {
                appState.requestAddFile()
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
            QuickAction(label: "New Tab", icon: "plus.rectangle", section: "Terminal") {
                appState.createSurface()
            },
            QuickAction(label: "New YOLO Tab", icon: "bolt.fill", section: "Terminal") {
                appState.createSurfaceRunning(yoloCommand(store))
            },
            QuickAction(label: "Close Surface", icon: "xmark.rectangle", section: "Terminal") {
                appState.closeSurface(sid)
            },
            QuickAction(label: "Zoom", icon: "arrow.up.left.and.arrow.down.right", section: "Terminal") {
                appState.togglePaneZoom(sid)
            },
            // Resizes the real pane on the Mac to this phone's grid (herdr
            // only) so full-screen TUIs lay out for the phone; released when
            // focus leaves the surface. The label reflects the current state.
            QuickAction(label: appState.fittedSurfaces[sid] != nil ? "Unfit Pane" : "Fit to Phone",
                        icon: appState.fittedSurfaces[sid] != nil ? "iphone.slash" : "iphone",
                        section: "Terminal") {
                appState.toggleFitToPhone(sid)
            },
            QuickAction(label: "Search", icon: "magnifyingglass", section: "Terminal") {
                onOpenSearch()
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

        // Hand this session to the other machine (herdr bridges with a saved
        // handoff machine only).
        if appState.handoffInfo != nil {
            builtIn.append(QuickAction(label: "Move Session", icon: "arrow.up.forward.app", section: "Workspace") {
                appState.startHandoff(direction: "out", surfaceID: sid)
            })
        }

        // Filter out hidden built-in actions
        var result = builtIn.filter { !store.isBuiltInHidden($0.label) }

        // Append visible custom actions
        for custom in store.customActions where !custom.isHidden {
            result.append(QuickAction(label: custom.label, icon: custom.icon, section: custom.section) {
                appState.sendText(custom.command, to: sid)
            })
        }

        // Count every run, whichever way it was triggered (menu, chip, volume).
        result = result.map { qa in
            QuickAction(label: qa.label, icon: qa.icon, section: qa.section) {
                store.recordUse(qa.label)
                qa.action()
            }
        }

        if includeTop {
            let top = result
                .filter { store.usage($0.label) >= 2 }
                .sorted { store.usage($0.label) > store.usage($1.label) }
                .prefix(4)
            result = top.map { QuickAction(label: $0.label, icon: $0.icon, section: "Top", action: $0.action) } + result
        }

        return result
    }

    /// The pinned actions, in the user's pinned order, for the chip strip.
    @MainActor
    static func pinned(from actions: [QuickAction], store: QuickActionStore) -> [QuickAction] {
        store.pinnedLabels.compactMap { label in actions.first(where: { $0.label == label }) }
    }
}

@MainActor
final class QuickActionState: ObservableObject {
    @Published var isOpen = false
    @Published var isFullscreen = false
    @Published var selectedIndex = 0
    @Published var currentSectionIndex = 0
    var actions: [QuickAction] = []

    private static let canonicalOrder = ["Top", "Input", "Terminal", "Workspace", "AI"]

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
    @AppStorage("volumeButtonControls") private var volumeButtonControls = false
    @StateObject private var volumeHandler = VolumeButtonHandler()
    @StateObject private var speechManager = SpeechInputManager()
    @StateObject private var quickAction = QuickActionState()
    @State private var lastNotificationCount = 0
    @State private var isEditingTranscript = false
    @State private var editingText = ""
    @State private var contentPollTimer: Timer?
    // True while the composer is focused: landscape drops the header for
    // room, and dismissKeyboard() clears it to lower the keyboard.
    @State private var keyboardActive = false
    // Find-in-surface over the focused card's text — the conversation for a
    // claude surface, the terminal mirror plus its scrollback otherwise.
    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var searchMatchIndex = 0
    @State private var searchMatchCount = 0
    // Bumped to ask the focused card to jump to its newest output. A counter,
    // not a bool: every tap must land, including two in a row.
    @State private var scrollToBottomRequest = 0
    @FocusState private var searchFieldFocused: Bool
    // "Add File" flow: the source menu, then whichever picker was chosen.
    @State private var showAddMenu = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?
    // The card switcher: every surface as a scrollable grid of cards, and the
    // only place several surfaces show at once.
    @State private var showSwitcher = false
    // Screenshot fixture: open every work row in the focused chat.
    @State private var fixtureExpandWork = false
    @State private var fixtureExpandCommands = false
    /// Screenshot fixture: `-UITestScroll top|mid` opens the chat there.
    private var fixtureChatOpen: ChatScrollView<ChatTranscriptView>.OpenPosition? {
        guard appState.isFixtureMode else { return nil }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-UITestScroll"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "top": return .top
        case "mid": return .fraction(0.5)
        default: return nil
        }
    }
    /// Screenshot fixture: `-UITestDraft "/"` starts the composer with a draft.
    private var fixtureDraft: String {
        guard appState.isFixtureMode else { return "" }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-UITestDraft"), i + 1 < args.count else { return "" }
        return args[i + 1]
    }
    @Environment(\.verticalSizeClass) private var vSizeClass

    var body: some View {
        ZStack {
            Theme.c.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Landscape with the keyboard up has no height to spare.
                if !quickAction.isFullscreen, !(keyboardActive && vSizeClass == .compact) {
                    header
                }

                if appState.surfaces.isEmpty {
                    emptyState
                } else {
                    surfaceLayout
                }

                if let handoff = appState.handoffStatus, !quickAction.isFullscreen {
                    handoffBanner(handoff)
                        .padding(.bottom, 4)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if let status = appState.imagePasteStatus, !quickAction.isFullscreen {
                    Text(status)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                        )
                        .padding(.bottom, 4)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if isSearching, !quickAction.isFullscreen, !quickAction.isOpen {
                    searchBar
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Always-available remote keyboard for the focused terminal.
                if !quickAction.isFullscreen, !quickAction.isOpen,
                   let sid = appState.focusedSurfaceID,
                   let surface = appState.surfaces.first(where: { $0.id == sid }),
                   !surface.isBrowser {
                    TerminalInputBar(
                        surfaceID: sid,
                        surfaceTitle: surface.title,
                        chatMode: appState.showsChat(surface),
                        isAgent: surface.hasTranscript,
                        isWorking: appState.isAgentWorking(surface),
                        isRecording: speechManager.isRecording,
                        onToggleDictation: { toggleDictation() },
                        isActive: $keyboardActive,
                        onSend: { text, withEnter in
                            appState.sendComposed(text: text, withEnter: withEnter, to: sid)
                        },
                        onSendText: { appState.sendText($0, to: sid) },
                        onSendKey: { appState.sendKey($0, to: sid) },
                        hasPendingAttachment: appState.pendingAttachment != nil,
                        pendingThumbnail: appState.pendingAttachment?.thumbnail,
                        pendingLabel: appState.pendingAttachment?.label ?? "",
                        onAddFile: { dismissKeyboard(); showAddMenu = true },
                        onRemoveAttachment: { appState.clearPendingImage() },
                        onSwipeUp: { openSwitcher() },
                        seenCommands: SlashCommands.seen(in: appState.transcriptEvents[sid] ?? []),
                        initialDraft: fixtureDraft
                    )
                }
            }
            .animation(.easeInOut(duration: 0.22), value: keyboardActive)
            .animation(.easeInOut(duration: 0.2), value: isSearching)
            .animation(.easeInOut(duration: 0.2), value: appState.imagePasteStatus)
            .animation(.easeInOut(duration: 0.2), value: appState.handoffStatus)

            // Quick action overlay
            if quickAction.isOpen {
                quickActionOverlay
            }

            if showSwitcher {
                SurfaceSwitcherView(
                    peeker: appState.devicePeeker,
                    isPresented: $showSwitcher,
                    workspaceLabel: { workspaceLabel(for: $0, at: $1) },
                    onSelect: { id in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            appState.focusSurface(id)
                            showSwitcher = false
                        }
                    },
                    onNewTab: {
                        quickActionStore.recordUse("New Tab")
                        appState.createSurface()
                        showSwitcher = false
                    },
                    onNewYoloTab: {
                        quickActionStore.recordUse("New YOLO Tab")
                        appState.createSurfaceRunning(QuickActionBuilder.yoloCommand(quickActionStore))
                        showSwitcher = false
                    },
                    onRefresh: {
                        appState.refreshSurfaces()
                        fetchAllContent()
                    },
                    yoloCommand: { QuickActionBuilder.yoloCommand(quickActionStore) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: showSwitcher)
        // Swipe in from the left edge: back to the grid (the iOS back
        // gesture). Off whenever something covers the session.
        .background(
            LeftEdgeSwipe(
                isEnabled: !showSwitcher && !quickAction.isOpen && !isEditingTranscript
                    && appState.presentedHistory == nil && appState.linkSheet == nil && !appState.surfaces.isEmpty,
                onSwipe: edgeSwipe
            )
        )
        // Links in chat and history open over the session (LinkRouter).
        .environment(\.openURL, OpenURLAction { url in
            appState.openLink(url)
            return .handled
        })
        .sheet(item: $appState.linkSheet) { target in
            SafariSheet(url: target.url) { appState.linkSheet = nil }
                .ignoresSafeArea()
        }
        .onChange(of: showSwitcher) { _, open in
            // Background cards only refresh every ~15s; bring every preview
            // up to date the moment the grid opens.
            if open {
                dismissKeyboard()
                fetchAllContent()
            }
        }
        .onChange(of: showAddMenu) { _, open in if open { dismissKeyboard() } }
        .onChange(of: appState.surfaces.map(\.id)) { _, _ in
            // Switching workspace inside the switcher loads a new set.
            if showSwitcher { fetchAllContent() }
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
        .fullScreenCover(item: $appState.presentedHistory) { target in
            TranscriptSheetView(target: target)
                .environmentObject(appState)
        }
        // Add File: choose a source, then attach it to the compose bar. The
        // quick action funnels through appState.addFileRequested since the
        // quick-action builder has no view state of its own.
        .onChange(of: appState.addFileRequested) { _, requested in
            if requested {
                appState.addFileRequested = false
                showAddMenu = true
            }
        }
        .confirmationDialog("Add File", isPresented: $showAddMenu, titleVisibility: .visible) {
            Button("Photo Library") { showPhotoPicker = true }
            Button("Files") { showFileImporter = true }
            if UIPasteboard.general.hasImages {
                Button("Paste Image") { appState.attachClipboardImage() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    appState.attachPhoto(data: data)
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                appState.attachFile(url: url)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: quickAction.isOpen)
        .onChange(of: searchQuery) { _, _ in
            searchMatchIndex = 0
        }
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
        .onChange(of: appState.currentWorkspaceID) { _, _ in dismissKeyboard() }
        .onChange(of: appState.focusedSurfaceID) { _, _ in
            // Another surface is a new context: nothing typed carries over.
            dismissKeyboard()
            // Matches belong to the surface they were found in; carrying an
            // index across a surface switch points at nothing.
            if isSearching { closeSearch() }
            // Fetch the newly focused surface right away. focusSurface() does
            // this for a local tap, but focus also changes through the pane
            // list (cmux reporting a focus change, or the brief flap while a
            // switch settles) with no tap — and then the card sat on just the
            // live viewport, its conversation not loading until the 3s poll.
            // That was the "proper view only shows once the keyboard is up"
            // bug: the keyboard press merely coincided with a poll.
            if let focused = focusedSurface {
                fetchContent(for: focused)
            }
            // Clear notifications for newly focused surface after a moment
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                appState.clearNotificationsForFocusedSurface()
            }
        }
        // A dark-only app: semantic label colours, materials and menus all
        // resolve against dark.
        .preferredColorScheme(.dark)
        .onAppear {
            if !appState.isFixtureMode {
                appState.refreshSurfaces()
                speechManager.requestPermissions()
            }
            wireVolumeCallbacks()
            // Screenshot fixture flags (ios/scripts/screenshots.sh).
            if appState.isFixtureMode {
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-UITestSwitcher") { showSwitcher = true }
                if args.contains("-UITestExpandWork") { fixtureExpandWork = true }
                if args.contains("-UITestExpandCommands") { fixtureExpandCommands = true }
                // The composer's recording look only; no audio is started.
                if args.contains("-UITestRecording") { speechManager.isRecording = true }
                // `-UITestFind <query>`: Find open with a query typed.
                if let i = args.firstIndex(of: "-UITestFind"), i + 1 < args.count {
                    isSearching = true
                    searchQuery = args[i + 1]
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if volumeButtonControls { volumeHandler.start() }
            }
            startContentPolling()
        }
        .onDisappear {
            contentPollTimer?.invalidate()
            contentPollTimer = nil
        }
        .onChange(of: volumeButtonControls) { _, enabled in
            // Belt-and-braces. Today MainTabView switches on selectedTab, so
            // visiting Settings tears this view down and the toggle is picked
            // up by onAppear on the way back. This keeps the handler honest if
            // the tab ever starts retaining its view.
            if enabled {
                volumeHandler.start()
            } else {
                volumeHandler.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Restart volume handler — iOS can deactivate AVAudioSession
            // when backgrounded, interrupted, or idle, killing the KVO observer
            if volumeButtonControls { volumeHandler.start() }
            appState.refreshSurfaces()
            // Content polling can be left dead after a background/tab switch
            // (the timer was invalidated but onAppear never re-fired). Restart
            // it here so terminal content resumes updating without a manual
            // navigation back into the view.
            startContentPolling()
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))

            TextField("", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .tint(.white.opacity(0.6))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searchFieldFocused)
                .onSubmit { stepSearch(1) }
                .overlay(alignment: .leading) {
                    if searchQuery.isEmpty {
                        Text("find in surface")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.25))
                            .allowsHitTesting(false)
                    }
                }

            // Count first, so the reader sees whether stepping is worth it.
            Text(searchCountLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(searchMatchCount > 0 ? 0.5 : 0.25))
                .monospacedDigit()

            Button { dismissKeyboard(); stepSearch(-1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 13, weight: .semibold))
            }
            .disabled(searchMatchCount == 0)
            Button { dismissKeyboard(); stepSearch(1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
            }
            .disabled(searchMatchCount == 0)
            Button { closeSearch() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
            }
        }
        .tint(.white.opacity(0.6))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var searchCountLabel: String {
        if searchQuery.isEmpty { return "" }
        if searchMatchCount == 0 { return "none" }
        // The renderer stops counting at its cap, so say so rather than
        // implying the last match is the last one in the surface.
        let total = searchMatchCount >= TextSearch.maxMatches ? "\(TextSearch.maxMatches)+" : "\(searchMatchCount)"
        return "\(searchMatchIndex + 1)/\(total)"
    }

    /// Lowers the composer's keyboard (or Find's) for an action that
    /// doesn't need it: the grid, a menu, quick actions, a chat button.
    private func dismissKeyboard() {
        keyboardActive = false
        Keyboard.dismiss()
    }

    /// The grid. Opened from the header button, a swipe up on the composer
    /// or a swipe in from the left edge.
    private func openSwitcher() {
        dismissKeyboard()
        showSwitcher = true
    }

    /// The left-edge swipe: back to the grid. While dictating it opens the
    /// transcript editor instead, as a sideways swipe always has.
    private func edgeSwipe() {
        if speechManager.isRecording {
            editingText = speechManager.stop()
            volumeHandler.clearSpeechState()
            isEditingTranscript = true
            return
        }
        openSwitcher()
    }

    private func openSearch() {
        isSearching = true
        searchFieldFocused = true
    }

    private func closeSearch() {
        isSearching = false
        searchFieldFocused = false
        searchQuery = ""
        searchMatchIndex = 0
        searchMatchCount = 0
    }

    private func stepSearch(_ delta: Int) {
        guard searchMatchCount > 0 else { return }
        searchMatchIndex = TextSearch.step(from: searchMatchIndex, by: delta, count: searchMatchCount)
    }

    // MARK: - Quick actions

    private func openQuickActions() {
        guard let surface = focusedSurface else { return }
        dismissKeyboard()
        quickAction.open(with: buildActions(for: surface.id, includeTop: true))
    }

    private func buildActions(for sid: String, includeTop: Bool) -> [QuickAction] {
        QuickActionBuilder.build(
            surfaceID: sid,
            appState: appState,
            store: quickActionStore,
            includeTop: includeTop,
            onToggleFullscreen: { [quickAction] in quickAction.isFullscreen.toggle() },
            onOpenSearch: { openSearch() }
        )
    }

    /// Pinned actions for the header's ••• menu (New Tab and Claude YOLO by
    /// default), so the common ones skip the All Actions sheet.
    private func pinnedActions(for sid: String) -> [QuickAction] {
        QuickActionBuilder.pinned(from: buildActions(for: sid, includeTop: false), store: quickActionStore)
            .map { qa in
                QuickAction(label: qa.label, icon: qa.icon, section: qa.section) {
                    qa.action()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        appState.refreshSurfaces()
                    }
                }
            }
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
                    hintLabel(key: "PIN", label: "in settings")
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

    /// The open surface fills everything between the header and the
    /// composer. Other surfaces are reached through the grid or the volume
    /// buttons; never shown beside this one.
    private var surfaceLayout: some View {
        GeometryReader { geo in
            // iPhones report .compact width in both orientations, so size class
            // can't tell us portrait vs landscape — compare the actual bounds.
            let isLandscape = geo.size.width > geo.size.height
            if let surface = focusedSurface {
                focusedCard(for: surface, contentScale: isLandscape ? 1.0 : 1.25)
                    // The terminal text view brings its own 8pt inset; chat
                    // sets its own 20pt margins.
                    .padding(.horizontal, appState.showsChat(surface) ? 0 : 4)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    // The open surface. It has no long-press of its own (that selects
    // text); quick actions open from the header's ••• menu. Other surfaces are
    // reached through the grid (left-edge swipe, the header's grid button,
    // swipe up on the composer) or the volume buttons.
    private func focusedCard(for surface: Surface, contentScale: CGFloat) -> some View {
        PaneCardView(
            title: surface.title,
            isFocused: true,
            hasNotification: appState.hasNotification(for: surface) || appState.needsYouSurfaces.contains(surface.id),
            isTranscribing: speechManager.isRecording,
            transcript: speechManager.transcript,
            terminalText: surface.isBrowser ? "" : appState.cardText(for: surface),
            contentScale: contentScale,
            liveScreen: surface.isBrowser ? nil : appState.screenModels[surface.id],
            onLiveSizeChanged: { appState.reportLiveCardSize(surface.id, $0) },
            liveHistoryText: surface.hasTranscript
                ? (appState.claudeTranscript[surface.id] ?? "")
                : (appState.surfaceContent[surface.id] ?? ""),
            liveHistoryIsPolledScreen: !surface.hasTranscript,
            isBrowser: surface.isBrowser,
            browserURL: appState.browserURLs[surface.id] ?? "",
            canOpenHistory: surface.hasTranscript,
            onOpenHistory: { openHistory(fallback: surface) },
            isWorking: appState.workingSurfaces.contains(surface.id),
            searchQuery: isSearching ? searchQuery : "",
            currentMatchIndex: searchMatchIndex,
            onSearchMatchCount: { count in
                guard searchMatchCount != count else { return }
                searchMatchCount = count
                // The text under an active search keeps changing (the focused
                // surface repolls every few seconds), so an index that was
                // valid a moment ago can now be past the end.
                searchMatchIndex = TextSearch.clamp(searchMatchIndex, to: count)
            },
            scrollToBottomRequest: scrollToBottomRequest,
            onJumpToBottom: { scrollToBottomRequest += 1 },
            chatBody: chatBody(for: surface),
            glanceBody: nil
        )
        .id(surface.id)
    }

    private func openHistory(fallback surface: Surface) {
        // Resolve the CURRENTLY focused surface at fire time rather than
        // capturing this card's `surface`. During a cycle transition the
        // outgoing focused card stays mounted (and keeps firing scroll
        // callbacks) for the animation's duration, so a captured id would
        // open history for the surface you just left. Reading live focus
        // guarantees history always matches what's on screen.
        let focused = appState.surfaces.first(where: { $0.id == appState.focusedSurfaceID })
            ?? surface
        guard focused.hasTranscript else { return }
        appState.presentedHistory = HistoryTarget(id: focused.id, title: focused.title)
    }

    /// The focused card's chat body, when its surface is an agent session
    /// with typed events and hasn't been flipped to Terminal.
    private func chatBody(for surface: Surface) -> ChatCardBody? {
        guard !surface.isBrowser, appState.showsChat(surface) else { return nil }
        let sid = surface.id
        return ChatCardBody(
            events: appState.transcriptEvents[sid] ?? [],
            items: appState.chatItems(for: sid),
            pending: appState.pendingStates[sid],
            screenDialog: appState.screenDialogs[sid],
            isWorking: appState.isAgentWorking(surface),
            screen: appState.screenModels[sid],
            screenText: appState.surfaceContent[sid] ?? "",
            hasMore: appState.transcriptHasMore[sid] ?? false,
            isLoadingOlder: appState.transcriptPageLoading.contains(sid),
            lastViewedEventID: appState.lastViewedEvent(for: sid),
            lastViewedAt: appState.lastViewedTime(for: sid),
            onSendKey: { dismissKeyboard(); appState.sendKey($0, to: sid) },
            onShowTerminal: { appState.setChatBody(false, for: sid) },
            onMarkViewed: { appState.markViewed(sid, eventID: $0) },
            onNearTop: { appState.requestOlderEvents(sid) },
            scrollToBottomRequest: scrollToBottomRequest,
            onJumpToBottom: { scrollToBottomRequest += 1 },
            searchQuery: isSearching ? searchQuery : "",
            currentMatchIndex: searchMatchIndex,
            onSearchMatchCount: { count in
                guard searchMatchCount != count else { return }
                searchMatchCount = count
                searchMatchIndex = TextSearch.clamp(searchMatchIndex, to: count)
            },
            expandAllWork: fixtureExpandWork,
            expandCommands: fixtureExpandCommands,
            fixtureOpen: fixtureChatOpen,
            onInteract: { dismissKeyboard() }
        )
    }

    /// Show as Chat / Show as Terminal, offered in the ••• menu of an agent
    /// surface that can show chat.
    private func chatToggle(for surface: Surface) -> Binding<Bool>? {
        guard surface.hasTranscript, appState.transcriptEvents[surface.id] != nil else { return nil }
        let sid = surface.id
        return Binding(
            get: { appState.chatBodyOverride[sid] != "terminal" },
            set: { appState.setChatBody($0, for: sid) }
        )
    }

    // MARK: - Header

    /// The one header: switcher, title and status, ••• menu.
    private var header: some View {
        let surface = appState.surfaces.isEmpty ? nil : focusedSurface
        return SurfaceHeader(
            title: surface.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "No surfaces",
            subtitle: surface.map(subtitle(for:)) ?? currentWorkspaceName,
            isRecording: speechManager.isRecording,
            position: surfacePositionLabel,
            othersNeedYou: !appState.needsYouSurfaces.subtracting([surface?.id ?? ""]).isEmpty,
            onOpenSwitcher: { openSwitcher() },
            onOpenMenu: { dismissKeyboard() }
        ) {
            headerMenu(for: surface)
        }
    }

    private var surfacePositionLabel: String {
        let count = appState.surfaces.count
        guard count > 0 else { return "0" }
        let idx = appState.surfaces.firstIndex(where: { $0.id == focusedSurface?.id }) ?? 0
        return "\(idx + 1)/\(count)"
    }

    private var currentWorkspaceName: String {
        guard let index = appState.visibleWorkspaces.firstIndex(where: { $0.id == appState.currentWorkspaceID }) else { return "" }
        return workspaceLabel(for: appState.visibleWorkspaces[index], at: index)
    }

    /// Status and kind in a few words: "Working · claude", "Needs approval",
    /// "Done · 3h ago", "Terminal".
    private func subtitle(for surface: Surface) -> String {
        if surface.isBrowser {
            let url = appState.browserURLs[surface.id] ?? ""
            return URL(string: url)?.host ?? "Browser"
        }
        let kind = surface.agentKind ?? ""
        if surface.hasTranscript, let events = appState.transcriptEvents[surface.id] {
            switch appState.glance(for: surface).status {
            case .working: return "Working · \(kind)"
            case .approve: return "Needs approval"
            case .asks: return "Asks you a question"
            case .waiting: return "Waiting on you"
            case .done:
                if let ts = events.last(where: { $0.ts != nil })?.ts, let ago = ChatTime.ago(ts) {
                    return ago == "now" ? "Done · just now" : "Done · \(ago) ago"
                }
                return "Done · \(kind)"
            }
        }
        if surface.hasTranscript {
            return appState.isAgentWorking(surface) ? "Working · \(kind)" : kind
        }
        return appState.workingSurfaces.contains(surface.id) ? "Running" : "Terminal"
    }

    /// Everything the old title bar and bottom bar carried, in one menu.
    @ViewBuilder
    private func headerMenu(for surface: Surface?) -> some View {
        if let surface {
            if let chat = chatToggle(for: surface) {
                Picker("View", selection: chat) {
                    Label("Show as Chat", systemImage: "text.bubble").tag(true)
                    Label("Show as Terminal", systemImage: "terminal").tag(false)
                }
                .pickerStyle(.inline)
            }
            Section {
                newTabButton
                ForEach(pinnedActions(for: surface.id).filter { $0.label != "New Tab" }) { qa in
                    Button(qa.label, systemImage: qa.icon) { qa.action() }
                }
            }
            Section {
                if !surface.isBrowser {
                    Button("Find", systemImage: "magnifyingglass") { openSearch() }
                }
                // A chat is the whole conversation already; History is for
                // an agent shown as Terminal (or an old bridge's text card).
                if surface.hasTranscript, !appState.showsChat(surface) {
                    Button("History", systemImage: "clock.arrow.circlepath") { openHistory(fallback: surface) }
                }
                Button("All Actions", systemImage: "square.grid.3x3") { openQuickActions() }
            }
        } else {
            newTabButton
        }
        if appState.bridges.count > 1 {
            // Which device this is, and a way to another without Settings.
            Menu {
                Picker("Device", selection: Binding(
                    get: { appState.selectedBridge?.id },
                    set: { id in if let id { appState.selectBridge(id) } }
                )) {
                    ForEach(appState.bridges) { bridge in
                        Text(DeviceName.short(bridge.name)).tag(Optional(bridge.id))
                    }
                }
            } label: {
                Label("Device: " + DeviceName.short(appState.selectedBridge?.name ?? ""), systemImage: "desktopcomputer")
            }
        }
        Section {
            Button("Menu", systemImage: "sidebar.left") { appState.sidebarRevealRequest += 1 }
            Button {} label: {
                Label(appState.connectionStatus.label(backend: appState.backendKind), systemImage: connectionSymbol)
            }
            .disabled(true)
        }
    }

    private var newTabButton: some View {
        Button("New Tab", systemImage: "plus.square") {
            quickActionStore.recordUse("New Tab")
            appState.createSurface()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { appState.refreshSurfaces() }
        }
    }

    private var connectionSymbol: String {
        switch appState.connectionStatus {
        case .connected(true): return "checkmark.circle"
        case .connected(false), .reconnecting, .connecting: return "exclamationmark.circle"
        case .disconnected: return "xmark.circle"
        }
    }

    // MARK: - Handoff banner

    /// Progress of a session handoff, then its outcome with a button to follow
    /// the sessions to the machine they moved to. Tap the text to dismiss.
    private func handoffBanner(_ status: HandoffStatus) -> some View {
        HStack(spacing: 8) {
            if case .running = status {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
            Text(status.summary)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
                .onTapGesture { dismissKeyboard(); appState.dismissHandoff() }
            if case .done(let done) = status, done.direction == "out", done.moved > 0, done.bridge != nil {
                Button {
                    dismissKeyboard()
                    appState.followHandoff()
                } label: {
                    Text(appState.handoffTargetBridge == nil ? "Pair \(done.machine)" : "Open")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.c.attention))
                }
                .buttonStyle(.plain)
            }
            if case .done = status {
                Button {
                    dismissKeyboard()
                    appState.dismissHandoff()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
        )
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

    // MARK: - Workspace labels

    private func workspaceLabel(for ws: Workspace, at index: Int) -> String {
        let title = appState.displayTitle(for: ws)
        // Only fall back to a positional label if cmux gave us nothing usable:
        // the raw id, or something UUID-shaped. The length floor keeps short
        // hexy-looking real titles ("cafe", "dead-beef") from being swallowed.
        let looksLikeID = title == ws.id
            || (title.count >= 32 && title.allSatisfy { $0.isHexDigit || $0 == "-" })
        if looksLikeID {
            return "Workspace \(index + 1)"
        }
        return title
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
                // Surface metadata otherwise only refreshes on an action or an
                // event. That leaves a terminal where claude was just started
                // looking like a plain shell — no conversation, no history
                // affordance — until something else happens to reload the list.
                // One cheap surface.list every 5th cycle keeps agent kind and
                // titles current; setIfChanged means an unchanged list is not
                // even a re-render.
                if self.pollCycleCount % 5 == 0 {
                    appState.refreshSurfaces()
                }
            }
        }
    }

    private func fetchAllContent() {
        for surface in appState.surfaces { fetchContent(for: surface) }
    }

    private func fetchContent(for surface: Surface) {
        if surface.isBrowser {
            appState.readBrowserURL(surface.id)
            return
        }
        // Live terminal mirror: deep read when focused (scrollback for plain
        // shells), cheap preview otherwise, none for a chat card that draws
        // nothing from the screen (AppState.screenReadLines).
        if let lines = appState.screenReadLines(for: surface, focused: surface.id == appState.focusedSurfaceID) {
            appState.readSurfaceText(surface.id, lines: lines)
        }
        // A claude/opencode surface's card is its conversation, so keep its
        // transcript current alongside the mirror. Background surfaces too
        // (they're only fetched every ~15s): their glance tiles and the
        // "needs you" dot read the events and pending state. Unchanged
        // transcripts answer from a fingerprint, so this poll is nearly free.
        if surface.hasTranscript {
            appState.loadClaudeTranscript(surface.id)
        }
    }

    // MARK: - Volume callbacks

    /// Volume-up's speech toggle, shared with the composer's mic button:
    /// start recording, or stop and send what was heard (with Enter when
    /// auto-submit is on).
    @MainActor
    static func toggleDictation(speech: SpeechInputManager, appState: AppState) async {
        if speech.isRecording {
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
            speech.start()
        }
    }

    private func toggleDictation() {
        let speech = speechManager
        let appState = appState
        Task { @MainActor in await Self.toggleDictation(speech: speech, appState: appState) }
    }

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
                } else {
                    await Self.toggleDictation(speech: speech, appState: appState)
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
                    qa.open(with: QuickActionBuilder.build(surfaceID: sid, appState: appState, store: store, includeTop: true, onToggleFullscreen: { qa.isFullscreen.toggle() }))
                }
            }
        }
    }
}
