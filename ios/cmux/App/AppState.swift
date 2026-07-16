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
    // Tracks the last surface explicitly focused by the user; used when surface.list
    // doesn't return is_focused and pane.list is unavailable.
    @Published private(set) var localFocusedSurfaceID: String?
    @Published var surfaceContent: [String: String] = [:]
    @Published var browserURLs: [String: String] = [:]

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
    private let pairingStore = PairingStore()
    private var client: BridgeClient?
    private var discovery: BridgeDiscovery?

    init() {
        startDiscovery()
        connectIfPaired()
        requestNotificationPermission()
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

        let request = UNNotificationRequest(
            identifier: n.id,
            content: content,
            trigger: nil // deliver immediately
        )
        center.add(request)
    }

    // MARK: - Pairing

    // A parsed pairing request awaiting the user's confirmation because it would
    // REPLACE an existing pairing (a silent re-pair from a hostile QR/deep-link
    // would otherwise redirect all keystrokes to an attacker's host).
    @Published var pendingPairing: PairingCredentials?

    func handlePairingURL(_ url: URL) {
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

        // First-time pairing (or re-pairing the exact same host) is committed
        // immediately. Any change to an existing pairing requires confirmation.
        if let existing = try? pairingStore.load(),
           existing.host != host || existing.port != port || existing.token != token {
            pendingPairing = credentials
            return
        }
        commitPairing(credentials)
    }

    /// Applies a pairing the user has confirmed (or that needed no confirmation).
    func commitPairing(_ credentials: PairingCredentials) {
        try? pairingStore.save(credentials)
        connect(to: credentials)
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

    func unpair() {
        client?.disconnect()
        client = nil
        try? pairingStore.delete()
        connectionStatus = .disconnected
        notifications = []
        workspaces = []
        surfaces = []
        panes = []
    }

    // MARK: - Connection

    func connectIfPaired() {
        guard let creds = try? pairingStore.load() else { return }
        connect(to: creds)
    }

    func connect(to credentials: PairingCredentials) {
        client?.disconnect()
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

    func selectWorkspace(_ id: String) {
        send(method: "workspace.select", params: ["workspace_id": id]) { [weak self] _ in
            self?.currentWorkspaceID = id
            self?.localFocusedSurfaceID = self?.lastFocusedSurface[id]
            self?.refreshSurfaces()
            self?.refreshPanes()
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
            guard let self, let text = result["text"] as? String else { return }
            let content = Self.capHistoryLines(Self.trimTerminalText(text))
            // Diff before assigning: a no-op write to a @Published dictionary
            // still fires objectWillChange every poll.
            if self.surfaceContent[surfaceID] != content {
                self.surfaceContent[surfaceID] = content
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
            let text = (result["text"] as? String).map(Self.trimTerminalText) ?? ""
            let sessionID = result["session_id"] as? String ?? ""
            // Diagnostic: the surface we asked for vs the session the bridge
            // resolved it to. If these ever look mismatched, this line names the
            // exact ids to chase (the bridge maps surface → resume_binding →
            // <checkpoint_id>.jsonl and echoes the resolved session_id back).
            print("[Transcript] surface=\(surfaceID) -> session=\(sessionID) (\(text.count) chars)")
            self.claudeTranscriptSession[surfaceID] = sessionID
            self.claudeTranscript[surfaceID] = text
        }
    }

    /// Trim trailing whitespace per line and remove blank trailing lines.
    nonisolated private static func trimTerminalText(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\\n+$", with: "", options: .regularExpression)
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
                self?.workspaces = list.compactMap(Workspace.init)
            }
            step()
        }
        send(method: "workspace.current", params: [:]) { [weak self] result in
            if let id = result["id"] as? String { self?.currentWorkspaceID = id }
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
                self?.surfaces = list.compactMap(Surface.init)
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
                self.surfaces = list.compactMap(Surface.init)
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
                self?.panes = list.compactMap(Pane.init)
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
        guard let focusedID = focusedSurfaceID else { return }
        notifications.removeAll { $0.surfaceID == focusedID }
    }

    // MARK: - Private helpers

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
        guard connectionStatus == .disconnected,
              let stored = try? pairingStore.load() else { return }
        if let match = candidates.first(where: { $0.host == stored.host && $0.port == stored.port }) {
            connect(to: PairingCredentials(host: match.host, port: match.port, token: stored.token, tailscaleHost: stored.tailscaleHost))
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
    let name: String

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        self.name = (dict["name"] as? String) ?? id
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
