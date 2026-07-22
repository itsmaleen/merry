import Foundation
import Combine
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var notifications: [BridgeNotification] = []
    @Published var workspaces: [Workspace] = []
    @Published var currentWorkspaceID: String?
    @Published var surfaces: [Surface] = []
    @Published var panes: [Pane] = []
    @Published var isPairingPresented = false
    // Paired bridges (Macs) and which one is currently active. Persisted in the
    // Keychain via BridgeStore; a single phone can hold several and switch.
    @Published var bridges: [SavedBridge] = []
    @Published var selectedBridgeID: UUID?
    // Tracks the last surface explicitly focused by the user; used when surface.list
    // doesn't return is_focused and pane.list is unavailable.
    @Published private(set) var localFocusedSurfaceID: String?
    @Published var surfaceContent: [String: String] = [:]
    @Published var browserURLs: [String: String] = [:]
    // Which sidebar tab is showing. Owned here (not in MainTabView) so a tapped
    // notification can bring the relevant surface into view on the Layout tab.
    @Published var selectedTab: SidebarTab = .layout

    // The live instance, so AppDelegate can route a tapped notification to it.
    // Weak so it doesn't keep a torn-down state alive.
    static private(set) weak var current: AppState?
    // A notification tapped before any AppState existed (cold launch straight
    // from a notification). Drained in init.
    private static var pendingLaunchTap: (surfaceID: String, workspaceID: String?)?
    // A surface to focus once the bridge finishes connecting, for a tap that
    // arrived while the session was still coming up. Applied in clientDidConnect.
    private var pendingNavigationTarget: (surfaceID: String, workspaceID: String?)?

    private var lastFocusedSurface: [String: String] = [:]
    // Claude conversation transcripts, loaded on demand for the full-screen
    // history viewer (kept separate from surfaceContent, which mirrors the live
    // terminal). Keyed by surface ID.
    @Published var claudeTranscript: [String: String] = [:]
    // The session id the bridge resolved each surface's transcript to, keyed by
    // surface ID. Surfaced in the history viewer for diagnosing wrong-session reports.
    @Published var claudeTranscriptSession: [String: String] = [:]
    @Published var claudeTranscriptLoading: Set<String> = []
    // Non-nil while the full-screen conversation-history viewer is presented.
    @Published var presentedHistory: HistoryTarget?
    private let bridgeStore = BridgeStore()
    private var client: BridgeClient?
    private var discovery: BridgeDiscovery?

    init() {
        let loaded = bridgeStore.loadAll()
        bridges = loaded.bridges
        selectedBridgeID = loaded.selectedID ?? loaded.bridges.first?.id
        startDiscovery()
        connectSelected()
        requestNotificationPermission()
        Self.current = self
        if let tap = Self.pendingLaunchTap {
            Self.pendingLaunchTap = nil
            navigateToSurface(surfaceID: tap.surfaceID, workspaceID: tap.workspaceID)
        }
    }

    // MARK: - Notification navigation

    /// Routes a tapped notification to the live AppState, or stashes it until one
    /// comes up (cold launch straight from a notification).
    static func handleNotificationTap(surfaceID: String, workspaceID: String?) {
        if let current {
            current.navigateToSurface(surfaceID: surfaceID, workspaceID: workspaceID)
        } else {
            pendingLaunchTap = (surfaceID, workspaceID)
        }
    }

    /// Brings the surface referenced by a tapped notification into view: shows the
    /// Layout tab and, once connected, selects its workspace and focuses it.
    func navigateToSurface(surfaceID: String, workspaceID: String?) {
        selectedTab = .layout
        guard connectionStatus.isConnected else {
            // Cold launch: apply once clientDidConnect fires.
            pendingNavigationTarget = (surfaceID, workspaceID)
            return
        }
        applyNavigation(surfaceID: surfaceID, workspaceID: workspaceID)
    }

    private func applyNavigation(surfaceID: String, workspaceID: String?) {
        // Focus only after the workspace switch lands: selectWorkspace's
        // completion restores that workspace's last-remembered focus, which
        // would overwrite an eagerly applied one — and focusSurface records
        // lastFocusedSurface under currentWorkspaceID, which is stale until
        // the completion updates it.
        if let wsID = workspaceID, wsID != currentWorkspaceID {
            selectWorkspace(wsID) { [weak self] in
                self?.finishNavigation(surfaceID: surfaceID)
            }
        } else {
            finishNavigation(surfaceID: surfaceID)
        }
    }

    private func finishNavigation(surfaceID: String) {
        focusSurface(surfaceID)
        // That surface is now on screen, so its pending notifications are stale.
        if notifications.contains(where: { $0.surfaceID == surfaceID }) {
            notifications.removeAll { $0.surfaceID == surfaceID }
        }
    }

    /// The bridge whose session is (or should be) active.
    var selectedBridge: SavedBridge? {
        if let id = selectedBridgeID, let b = bridges.first(where: { $0.id == id }) { return b }
        return bridges.first
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            print("[Notification] push permission: \(granted)")
        }
    }

    private func scheduleLocalNotification(_ n: BridgeNotification) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = n.title
        if let subtitle = n.subtitle { content.subtitle = subtitle }
        if let body = n.body { content.body = body }
        content.sound = .default
        // Carry the surface/workspace so tapping the notification can bring that
        // surface into view (see AppDelegate.userNotificationCenter(_:didReceive:)).
        var info: [String: String] = [:]
        if let sid = n.surfaceID { info["surface_id"] = sid }
        if let wid = n.workspaceID { info["workspace_id"] = wid }
        content.userInfo = info

        let request = UNNotificationRequest(
            identifier: n.id,
            content: content,
            trigger: nil // deliver immediately
        )
        center.add(request)
    }

    // MARK: - Pairing

    // A parsed pairing request awaiting the user's confirmation because it would
    // add a new, not-yet-trusted bridge and switch input to it (a hostile
    // QR/deep-link could otherwise silently redirect all keystrokes).
    @Published var pendingPairing: PairingCredentials?

    /// Handles a pairing URL. `trusted` is true when the user initiated the
    /// pairing inside the app (scanning a QR from the pairing sheet, or manual
    /// entry) — those are explicit actions and are committed directly. It is
    /// false for an external `cmux-bridge://` deep link opened by another app,
    /// where a new bridge must be confirmed before it can take over input.
    func handlePairingURL(_ url: URL, trusted: Bool = false) {
        guard url.scheme == "cmux-bridge",
              url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.queryItems?.first(where: { $0.name == "host" })?.value,
              let portStr = components.queryItems?.first(where: { $0.name == "port" })?.value,
              let port = Int(portStr),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        else { return }

        let tailscaleHost = components.queryItems?.first(where: { $0.name == "tailscale_host" })?.value
        let credentials = PairingCredentials(host: host, port: port, token: token, tailscaleHost: tailscaleHost)

        // A bridge we already trust (same token) is just refreshing its network
        // coordinates — update it in place and switch to it, no confirmation.
        if bridges.contains(where: { $0.credentials.token == token }) {
            commitPairing(credentials)
            return
        }
        // Trust-on-first-use, or an explicit in-app pairing action: commit now.
        if bridges.isEmpty || trusted {
            commitPairing(credentials)
            return
        }
        // A new, unknown bridge arriving via an external deep link while others
        // exist: confirm before switching input to it.
        pendingPairing = credentials
    }

    /// Adds or updates a bridge from confirmed credentials, makes it active, and
    /// connects. A bridge with a matching token is updated in place (keeping its
    /// name); otherwise a new one is appended.
    func commitPairing(_ credentials: PairingCredentials) {
        let bridge: SavedBridge
        if let idx = bridges.firstIndex(where: { $0.credentials.token == credentials.token }) {
            bridges[idx].credentials = credentials
            bridge = bridges[idx]
        } else {
            bridge = SavedBridge(name: SavedBridge.defaultName(for: credentials), credentials: credentials)
            bridges.append(bridge)
        }
        selectedBridgeID = bridge.id
        persistBridges()
        resetSessionState()
        connect(to: bridge.credentials)
        isPairingPresented = false
        pendingPairing = nil
    }

    func confirmPendingPairing() {
        guard let pending = pendingPairing else { return }
        commitPairing(pending)
    }

    func cancelPendingPairing() {
        pendingPairing = nil
    }

    // MARK: - Bridge management

    /// Switches the active session to another paired bridge.
    func selectBridge(_ id: UUID) {
        guard id != selectedBridgeID, let bridge = bridges.first(where: { $0.id == id }) else { return }
        selectedBridgeID = id
        persistBridges()
        resetSessionState()
        connect(to: bridge.credentials)
    }

    /// Renames a paired bridge; an empty name falls back to the derived default.
    func renameBridge(_ id: UUID, to name: String) {
        guard let idx = bridges.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        bridges[idx].name = trimmed.isEmpty ? SavedBridge.defaultName(for: bridges[idx].credentials) : trimmed
        persistBridges()
    }

    /// Removes a paired bridge. If it was the active one, switches to another
    /// (or goes disconnected when none remain).
    func removeBridge(_ id: UUID) {
        let wasSelected = (id == selectedBridgeID)
        bridges.removeAll { $0.id == id }
        if wasSelected {
            client?.disconnect()
            client = nil
            selectedBridgeID = bridges.first?.id
            resetSessionState()
            if let next = selectedBridge {
                connect(to: next.credentials)
            } else {
                connectionStatus = .disconnected
            }
        }
        persistBridges()
    }

    /// Removes every paired bridge and returns to the pairing screen.
    func unpairAll() {
        client?.disconnect()
        client = nil
        bridges = []
        selectedBridgeID = nil
        persistBridges()
        resetSessionState()
        connectionStatus = .disconnected
    }

    private func persistBridges() {
        bridgeStore.persist(bridges: bridges, selectedID: selectedBridgeID)
    }

    /// Clears all per-connection UI state so switching bridges doesn't briefly
    /// show the previous Mac's workspaces/surfaces/notifications.
    private func resetSessionState() {
        notifications = []
        workspaces = []
        currentWorkspaceID = nil
        surfaces = []
        panes = []
        localFocusedSurfaceID = nil
        surfaceContent = [:]
        browserURLs = [:]
        claudeTranscript = [:]
        claudeTranscriptSession = [:]
        claudeTranscriptLoading = []
        presentedHistory = nil
        lastFocusedSurface = [:]
    }

    // MARK: - Connection

    func connectSelected() {
        guard let bridge = selectedBridge else { return }
        connect(to: bridge.credentials)
    }

    func connect(to credentials: PairingCredentials) {
        client?.disconnect()
        connectionStatus = .connecting
        let newClient = BridgeClient(credentials: credentials)
        newClient.delegate = self
        client = newClient
        newClient.connect()
    }

    // MARK: - Discovery

    private func startDiscovery() {
        let disc = BridgeDiscovery()
        disc.delegate = self
        self.discovery = disc
        disc.start()
    }

    // MARK: - Commands

    func selectWorkspace(_ id: String, then completion: (() -> Void)? = nil) {
        send(method: "workspace.select", params: ["workspace_id": id]) { [weak self] _ in
            self?.currentWorkspaceID = id
            self?.localFocusedSurfaceID = self?.lastFocusedSurface[id]
            self?.refreshSurfaces()
            self?.refreshPanes()
            completion?()
        }
    }

    func focusSurface(_ id: String) {
        localFocusedSurfaceID = id
        if let wsID = currentWorkspaceID {
            lastFocusedSurface[wsID] = id
        }
        // Immediately deep-read the newly focused surface so its content is
        // there right away instead of waiting for the next poll.
        if surfaces.first(where: { $0.id == id })?.isBrowser != true {
            readSurfaceText(id, lines: Self.focusedHistoryLines)
        }
        send(method: "surface.focus", params: ["surface_id": id]) { [weak self] _ in
            self?.refreshSurfaces()
            self?.refreshPanes()
        }
    }

    func focusPane(_ id: String) {
        send(method: "pane.focus", params: ["pane_id": id]) { [weak self] _ in
            self?.refreshPanes()
        }
    }

    func togglePaneZoom(_ surfaceID: String) {
        sendKey("cmd+shift+enter", to: surfaceID)
    }

    func cycleSurface() {
        let list = surfaces
        guard !list.isEmpty else { return }
        let currentIndex = list.firstIndex(where: { $0.id == focusedSurfaceID }) ?? -1
        let nextIndex = (currentIndex + 1) % list.count
        focusSurface(list[nextIndex].id)
    }

    func cycleSurfaceBackward() {
        let list = surfaces
        guard !list.isEmpty else { return }
        // Match cycleSurface's "nothing focused" fallback (-1) so forward and
        // backward agree on where cycling starts from an unfocused state.
        let currentIndex = list.firstIndex(where: { $0.id == focusedSurfaceID }) ?? -1
        let prevIndex = (currentIndex - 1 + list.count) % list.count
        focusSurface(list[prevIndex].id)
    }

    func cycleWorkspace() {
        guard !workspaces.isEmpty else { return }
        let currentIndex = workspaces.firstIndex(where: { $0.id == currentWorkspaceID }) ?? -1
        let nextIndex = (currentIndex + 1) % workspaces.count
        selectWorkspace(workspaces[nextIndex].id)
    }

    func cyclePane() {
        guard !panes.isEmpty else { return }
        let focusedIndex = panes.firstIndex(where: { $0.isFocused }) ?? -1
        let nextIndex = (focusedIndex + 1) % panes.count
        focusPane(panes[nextIndex].id)
    }

    func cycleTabInFocusedPane() {
        guard let focused = panes.first(where: { $0.isFocused }),
              focused.surfaceIDs.count > 1 else { return }
        let currentIndex = focused.surfaceIDs.firstIndex(of: focused.focusedSurfaceID ?? "") ?? -1
        let nextIndex = (currentIndex + 1) % focused.surfaceIDs.count
        focusSurface(focused.surfaceIDs[nextIndex])
    }

    func sendText(_ text: String, to surfaceID: String) {
        send(method: "surface.send_text", params: ["surface_id": surfaceID, "text": text])
    }

    func sendKey(_ key: String, to surfaceID: String) {
        send(method: "surface.send_key", params: ["surface_id": surfaceID, "key": key])
    }

    /// Reads a surface's text. cmux's `surface.read_text` returns the last
    /// `lines` rows *including terminal scrollback* — so a large `lines` value
    /// yields the scrollable history directly, with no separate load step. The
    /// focused surface asks for a deep window (history); background surfaces a
    /// shallow one (cheap live preview). Note: full-screen TUIs like claude-code
    /// repaint a fixed viewport and keep little/no terminal scrollback, so for
    /// those this returns roughly the visible screen — that's a cmux limitation,
    /// not a bug here. See [[project_cmux_no_scrollback]].
    func readSurfaceText(_ surfaceID: String, lines: Int = 50) {
        var params: [String: Any] = ["surface_id": surfaceID, "lines": lines]
        if let wsID = currentWorkspaceID {
            params["workspace_id"] = wsID
        }
        send(method: "surface.read_text", params: params) { [weak self] result in
            guard self != nil, let text = result["text"] as? String else { return }
            // Trim/cap off the main actor: a deep focused read is thousands of
            // lines, and doing that inline stalls whatever animation (keyboard,
            // card resize) happens to be in flight when the poll lands.
            Task.detached(priority: .userInitiated) { [weak self] in
                let content = Self.capHistoryLines(Self.trimTerminalText(text))
                await MainActor.run {
                    // Diff before assigning: a no-op write to a @Published
                    // dictionary still fires objectWillChange every poll.
                    guard let self, self.surfaceContent[surfaceID] != content else { return }
                    self.surfaceContent[surfaceID] = content
                }
            }
        }
    }

    /// How many rows to request for the focused surface — deep enough to scroll
    /// back through, bounded so a huge scrollback can't produce a payload that
    /// stalls the socket or an attributed string UITextView can't lay out.
    static let focusedHistoryLines = 1500

    /// Loads a claude surface's conversation history from its session transcript
    /// (via the bridge's `claude.transcript`) into `claudeTranscript`, for the
    /// full-screen history viewer. Claude runs as a full-screen TUI whose
    /// terminal exposes no scrollback, so the transcript is the real history.
    func loadClaudeTranscript(_ surfaceID: String) {
        guard !claudeTranscriptLoading.contains(surfaceID) else { return }
        claudeTranscriptLoading.insert(surfaceID)
        var params: [String: Any] = ["surface_id": surfaceID, "max_messages": 300]
        if let wsID = currentWorkspaceID {
            params["workspace_id"] = wsID
        }
        // Safety net: BridgeClient drops pending completions on disconnect
        // without calling them, so clear the loading flag on a timeout too —
        // otherwise the viewer's spinner would hang forever. Both paths do an
        // idempotent remove, so the race is harmless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.claudeTranscriptLoading.remove(surfaceID)
        }
        send(method: "claude.transcript", params: params) { [weak self] result in
            guard let self else { return }
            self.claudeTranscriptLoading.remove(surfaceID)
            let raw = result["text"] as? String ?? ""
            let sessionID = result["session_id"] as? String ?? ""
            // Diagnostic: the surface we asked for vs the session the bridge
            // resolved it to. If these ever look mismatched, this line names the
            // exact ids to chase (the bridge maps surface → resume_binding →
            // <checkpoint_id>.jsonl and echoes the resolved session_id back).
            print("[Transcript] surface=\(surfaceID) -> session=\(sessionID) (\(raw.count) chars)")
            self.claudeTranscriptSession[surfaceID] = sessionID
            // Trim off the main actor — transcripts can be hundreds of messages,
            // and this runs every time the history viewer opens.
            Task.detached(priority: .userInitiated) { [weak self] in
                let text = Self.trimTerminalText(raw)
                await MainActor.run {
                    guard let self, self.claudeTranscript[surfaceID] != text else { return }
                    self.claudeTranscript[surfaceID] = text
                }
            }
        }
    }

    /// Trim trailing whitespace per line and remove blank trailing lines.
    /// Plain character ops, no regex — this runs over thousands of lines per
    /// poll, and a per-line NSRegularExpression here dominated the poll cost.
    nonisolated private static func trimTerminalText(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for i in lines.indices {
            while let last = lines[i].last, last.isWhitespace {
                lines[i].removeLast()
            }
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// Bound history so a very long session doesn't produce an attributed
    /// string UITextView can't lay out interactively.
    nonisolated private static let maxHistoryLines = 5000

    nonisolated private static func capHistoryLines(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxHistoryLines else { return text }
        return lines.suffix(maxHistoryLines).joined(separator: "\n")
    }

    func readBrowserURL(_ surfaceID: String) {
        send(method: "browser.url.get", params: ["surface_id": surfaceID]) { [weak self] result in
            if let url = result["url"] as? String {
                self?.browserURLs[surfaceID] = url
            }
        }
    }

    func createWorkspace(name: String? = nil) {
        var params: [String: Any] = [:]
        if let name { params["name"] = name }
        send(method: "workspace.create", params: params) { [weak self] _ in
            self?.refreshWorkspaces()
            self?.refreshSurfaces()
        }
    }

    func closeWorkspace(_ id: String) {
        send(method: "workspace.close", params: ["workspace_id": id]) { [weak self] _ in
            self?.lastFocusedSurface.removeValue(forKey: id)
            // Select the next workspace only after the list is refreshed —
            // otherwise `workspaces` still contains the just-closed one.
            self?.refreshWorkspaces {
                guard let self, self.currentWorkspaceID == id else { return }
                if let next = self.workspaces.first(where: { $0.id != id }) {
                    self.selectWorkspace(next.id)
                }
            }
        }
    }

    func splitSurface(direction: String, surfaceID: String? = nil) {
        let previousIDs = Set(surfaces.map(\.id))
        var params: [String: Any] = ["direction": direction]
        if let surfaceID { params["surface_id"] = surfaceID }
        send(method: "surface.split", params: params) { [weak self] _ in
            self?.refreshSurfacesAndFocusNew(previousIDs: previousIDs)
        }
    }

    func createSurface(type: String = "terminal") {
        let previousIDs = Set(surfaces.map(\.id))
        send(method: "surface.create", params: ["type": type]) { [weak self] _ in
            self?.refreshSurfacesAndFocusNew(previousIDs: previousIDs)
        }
    }

    func closeSurface(_ surfaceID: String) {
        send(method: "surface.close", params: ["surface_id": surfaceID]) { [weak self] _ in
            self?.refreshSurfaces()
        }
    }

    func clearNotifications() {
        send(method: "notification.clear", params: [:]) { [weak self] _ in
            self?.notifications = []
        }
    }

    func refreshWorkspaces(then completion: (() -> Void)? = nil) {
        // Both list + current must land before firing `completion`, otherwise
        // follow-up work (refreshSurfaces) can run against an empty workspace
        // list or an unset current ID depending on which reply arrives first.
        // Both callbacks run on the main actor, so `pending` needs no locking.
        var pending = 2
        let step = {
            pending -= 1
            if pending == 0 { completion?() }
        }
        send(method: "workspace.list", params: [:]) { [weak self] result in
            if let list = result["workspaces"] as? [[String: Any]] {
                self?.setIfChanged(\.workspaces, to: list.compactMap(Workspace.init), by: Workspace.sameContent)
            }
            step()
        }
        send(method: "workspace.current", params: [:]) { [weak self] result in
            if let id = result["id"] as? String, id != self?.currentWorkspaceID {
                self?.currentWorkspaceID = id
            }
            step()
        }
    }

    func refreshSurfaces(workspaceID: String? = nil) {
        var params: [String: Any] = [:]
        if let id = workspaceID ?? currentWorkspaceID {
            params["workspace_id"] = id
        }
        send(method: "surface.list", params: params) { [weak self] result in
            if let list = result["surfaces"] as? [[String: Any]] {
                self?.setIfChanged(\.surfaces, to: list.compactMap(Surface.init), by: Surface.sameContent)
                // Validate remembered surface still exists
                if let localID = self?.localFocusedSurfaceID,
                   self?.surfaces.contains(where: { $0.id == localID }) == false {
                    self?.localFocusedSurfaceID = nil
                }
                // Auto-select first surface if nothing is focused
                if self?.focusedSurfaceID == nil, let first = self?.surfaces.first {
                    self?.localFocusedSurfaceID = first.id
                }
            }
        }
    }

    private func refreshSurfacesAndFocusNew(previousIDs: Set<String>) {
        var params: [String: Any] = [:]
        if let id = currentWorkspaceID {
            params["workspace_id"] = id
        }
        send(method: "surface.list", params: params) { [weak self] result in
            guard let self else { return }
            if let list = result["surfaces"] as? [[String: Any]] {
                self.setIfChanged(\.surfaces, to: list.compactMap(Surface.init), by: Surface.sameContent)
                if let newSurface = self.surfaces.first(where: { !previousIDs.contains($0.id) }) {
                    self.focusSurface(newSurface.id)
                } else if self.focusedSurfaceID == nil, let first = self.surfaces.first {
                    self.localFocusedSurfaceID = first.id
                }
            }
        }
    }

    func refreshPanes() {
        var params: [String: Any] = [:]
        if let id = currentWorkspaceID {
            params["workspace_id"] = id
        }
        send(method: "pane.list", params: params) { [weak self] result in
            if let list = result["panes"] as? [[String: Any]] {
                self?.setIfChanged(\.panes, to: list.compactMap(Pane.init), by: Pane.sameContent)
            }
        }
    }

    // MARK: - Helpers

    var focusedSurfaceID: String? {
        // Prefer pane-derived focus, then surface.is_focused, then local tracking
        panes.first(where: { $0.isFocused })?.focusedSurfaceID
            ?? surfaces.first(where: { $0.isFocused })?.id
            ?? localFocusedSurfaceID
    }

    var currentWorkspaceSurfaces: [Surface] {
        guard let wsID = currentWorkspaceID else { return surfaces }
        return surfaces.filter { $0.workspaceID == wsID }
    }

    func surfaceTitle(for id: String) -> String {
        surfaces.first(where: { $0.id == id })?.title ?? ""
    }

    func hasNotification(for pane: Pane) -> Bool {
        notifications.contains { n in
            guard let sid = n.surfaceID else { return false }
            return pane.surfaceIDs.contains(sid)
        }
    }

    func hasNotification(for surface: Surface) -> Bool {
        notifications.contains { $0.surfaceID == surface.id }
    }

    func clearNotificationsForFocusedSurface() {
        // Guard before mutating: this runs on delayed timers after every focus
        // change, and removeAll on a @Published array fires objectWillChange
        // even when nothing matches.
        guard let focusedID = focusedSurfaceID,
              notifications.contains(where: { $0.surfaceID == focusedID }) else { return }
        notifications.removeAll { $0.surfaceID == focusedID }
    }

    // MARK: - Private helpers

    /// Assigns a @Published list only when its content actually changed.
    /// The refresh RPCs re-fetch on every connect/foreground/focus change and
    /// usually return identical lists; an unconditional assign would fire
    /// objectWillChange each time and re-render every view observing AppState.
    /// Comparison is via an explicit closure, NOT Equatable conformance — these
    /// structs are SwiftUI view parameters, and conforming them to Equatable
    /// has caused missed re-renders here before.
    private func setIfChanged<T>(
        _ keyPath: ReferenceWritableKeyPath<AppState, [T]>, to value: [T],
        by same: (T, T) -> Bool
    ) {
        let current = self[keyPath: keyPath]
        if current.count != value.count || !zip(current, value).allSatisfy(same) {
            self[keyPath: keyPath] = value
        }
    }

    private func send(
        method: String,
        params: [String: Any],
        completion: (([String: Any]) -> Void)? = nil
    ) {
        client?.send(method: method, params: params, completion: completion)
    }
}

// MARK: - BridgeClientDelegate

extension AppState: BridgeClientDelegate {
    func clientDidConnect(_ client: BridgeClient) {
        connectionStatus = .connected
        refreshWorkspaces {
            self.refreshSurfaces()
            self.refreshPanes()
            // A notification tapped before the session was up (cold launch).
            if let tap = self.pendingNavigationTarget {
                self.pendingNavigationTarget = nil
                self.applyNavigation(surfaceID: tap.surfaceID, workspaceID: tap.workspaceID)
            }
        }
    }

    func clientDidDisconnect(_ client: BridgeClient, error: Error?) {
        connectionStatus = .reconnecting
        // In-flight transcript RPCs will never complete now; clear their loading
        // flags so the history viewer doesn't hang on a spinner.
        claudeTranscriptLoading.removeAll()
    }

    func clientDidReceiveMessage(_ client: BridgeClient, message: BridgeMessage) {
        switch message {
        case .connected(let payload):
            connectionStatus = .connected(cmuxConnected: payload.cmuxConnected)
        case .notificationCreated(let n):
            notifications.insert(n, at: 0)
            print("[Notification] id=\(n.id) surfaceID=\(n.surfaceID ?? "nil") workspaceID=\(n.workspaceID ?? "nil") title=\(n.title)")
            print("[Notification] surface IDs: \(surfaces.map(\.id))")
            scheduleLocalNotification(n)
        case .notificationCleared:
            notifications = []
        case .cmuxConnected:
            connectionStatus = .connected(cmuxConnected: true)
            refreshWorkspaces {
                self.refreshSurfaces()
                self.refreshPanes()
            }
        case .cmuxDisconnected:
            connectionStatus = .connected(cmuxConnected: false)
            panes = []
        case .commandResponse:
            break
        }
    }
}

// MARK: - BridgeDiscoveryDelegate

extension AppState: BridgeDiscoveryDelegate {
    func discovery(_ discovery: BridgeDiscovery, didFind candidates: [PairingCredentials]) {
        guard connectionStatus == .disconnected, let stored = selectedBridge else { return }
        let creds = stored.credentials
        if let match = candidates.first(where: { $0.host == creds.host && $0.port == creds.port }) {
            connect(to: PairingCredentials(host: match.host, port: match.port, token: creds.token, tailscaleHost: creds.tailscaleHost))
        }
    }
}

// MARK: - Models

struct BridgeNotification: Identifiable, Decodable {
    let id: String
    let title: String
    let subtitle: String?
    let body: String?
    let workspaceID: String?
    let surfaceID: String?
    let isRead: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, body
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case isRead = "is_read"
    }
}

struct Workspace: Identifiable {
    let id: String
    /// The display title cmux computes for the workspace (custom title, else the
    /// active conversation topic, else the working directory) — matches what the
    /// cmux UI shows. Falls back through older fields, then the id.
    let title: String

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        // First non-blank candidate wins — a present-but-empty field must not
        // shadow a usable later fallback.
        self.title = [dict["title"], dict["custom_title"], dict["name"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? id
    }

    // Deliberately NOT an Equatable conformance; see AppState.setIfChanged.
    static func sameContent(_ a: Workspace, _ b: Workspace) -> Bool {
        a.id == b.id && a.title == b.title
    }
}

struct Surface: Identifiable {
    let id: String
    let title: String
    let type: String
    let workspaceID: String?
    let isFocused: Bool
    /// Agent kind from cmux's resume_binding (e.g. "claude"), when this surface
    /// is running an agent. Used to offer conversation-transcript history.
    let agentKind: String?

    var isBrowser: Bool { type == "browser" }
    var isClaudeAgent: Bool { agentKind == "claude" }

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        self.type = (dict["type"] as? String) ?? "terminal"
        self.title = (dict["title"] as? String) ?? self.type
        self.workspaceID = dict["workspace_id"] as? String
        self.isFocused = dict["is_focused"] as? Bool ?? false
        self.agentKind = (dict["resume_binding"] as? [String: Any])?["kind"] as? String
    }

    // Deliberately NOT an Equatable conformance; see AppState.setIfChanged.
    static func sameContent(_ a: Surface, _ b: Surface) -> Bool {
        a.id == b.id && a.title == b.title && a.type == b.type
            && a.workspaceID == b.workspaceID && a.isFocused == b.isFocused
            && a.agentKind == b.agentKind
    }
}

struct Pane: Identifiable {
    let id: String
    let pixelFrame: CGRect
    let containerFrame: CGSize
    let surfaceIDs: [String]
    let focusedSurfaceID: String?
    let isFocused: Bool

    var normalizedFrame: CGRect {
        guard containerFrame.width > 0, containerFrame.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(
            x: pixelFrame.origin.x / containerFrame.width,
            y: pixelFrame.origin.y / containerFrame.height,
            width: pixelFrame.size.width / containerFrame.width,
            height: pixelFrame.size.height / containerFrame.height
        )
    }

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id

        if let pf = dict["pixel_frame"] as? [String: Any] {
            let x = (pf["x"] as? Double).map { CGFloat($0) } ?? 0
            let y = (pf["y"] as? Double).map { CGFloat($0) } ?? 0
            let w = (pf["width"] as? Double).map { CGFloat($0) } ?? 100
            let h = (pf["height"] as? Double).map { CGFloat($0) } ?? 100
            pixelFrame = CGRect(x: x, y: y, width: w, height: h)
        } else {
            pixelFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        }

        if let cf = dict["container_frame"] as? [String: Any] {
            let w = (cf["width"] as? Double).map { CGFloat($0) } ?? 100
            let h = (cf["height"] as? Double).map { CGFloat($0) } ?? 100
            containerFrame = CGSize(width: w, height: h)
        } else {
            containerFrame = CGSize(width: 100, height: 100)
        }

        surfaceIDs = dict["surface_ids"] as? [String] ?? []
        focusedSurfaceID = dict["focused_surface_id"] as? String
        isFocused = dict["is_focused"] as? Bool ?? false
    }

    // Deliberately NOT an Equatable conformance; see AppState.setIfChanged.
    static func sameContent(_ a: Pane, _ b: Pane) -> Bool {
        a.id == b.id && a.pixelFrame == b.pixelFrame
            && a.containerFrame == b.containerFrame && a.surfaceIDs == b.surfaceIDs
            && a.focusedSurfaceID == b.focusedSurfaceID && a.isFocused == b.isFocused
    }
}

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case reconnecting
    case connected(cmuxConnected: Bool = true)

    static var connected: ConnectionStatus { .connected(cmuxConnected: true) }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .connected(let cmux):
            return cmux ? "Connected" : "Bridge connected (cmux offline)"
        }
    }

    var color: String {
        switch self {
        case .connected(true): return "green"
        case .connected(false): return "yellow"
        case .reconnecting: return "yellow"
        case .connecting: return "yellow"
        case .disconnected: return "red"
        }
    }
}
