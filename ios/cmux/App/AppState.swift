import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var notifications: [BridgeNotification] = []
    @Published var workspaces: [Workspace] = []
    @Published var currentWorkspaceID: String?
    @Published var surfaces: [Surface] = []
    @Published var isPairingPresented = false

    private let pairingStore = PairingStore()
    private var client: BridgeClient?
    private var discovery: BridgeDiscovery?

    init() {
        startDiscovery()
        connectIfPaired()
    }

    // MARK: - Pairing

    func handlePairingURL(_ url: URL) {
        guard url.scheme == "cmux-bridge",
              url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.queryItems?.first(where: { $0.name == "host" })?.value,
              let portStr = components.queryItems?.first(where: { $0.name == "port" })?.value,
              let port = Int(portStr),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        else { return }

        let credentials = PairingCredentials(host: host, port: port, token: token)
        try? pairingStore.save(credentials)
        connect(to: credentials)
        isPairingPresented = false
    }

    func unpair() {
        client?.disconnect()
        client = nil
        try? pairingStore.delete()
        connectionStatus = .disconnected
        notifications = []
        workspaces = []
        surfaces = []
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
        send(method: "workspace.select", params: ["workspace_id": id])
    }

    func focusSurface(_ id: String) {
        send(method: "surface.focus", params: ["surface_id": id])
    }

    func sendText(_ text: String, to surfaceID: String) {
        send(method: "surface.send_text", params: ["surface_id": surfaceID, "text": text])
    }

    func sendKey(_ key: String, to surfaceID: String) {
        send(method: "surface.send_key", params: ["surface_id": surfaceID, "key": key])
    }

    func clearNotifications() {
        send(method: "notification.clear", params: [:]) { [weak self] _ in
            self?.notifications = []
        }
    }

    func refreshWorkspaces() {
        send(method: "workspace.list", params: [:]) { [weak self] result in
            if let list = result["workspaces"] as? [[String: Any]] {
                self?.workspaces = list.compactMap(Workspace.init)
            }
        }
        send(method: "workspace.current", params: [:]) { [weak self] result in
            self?.currentWorkspaceID = result["id"] as? String
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
            }
        }
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
        refreshWorkspaces()
        refreshSurfaces()
    }

    func clientDidDisconnect(_ client: BridgeClient, error: Error?) {
        connectionStatus = .reconnecting
    }

    func clientDidReceiveMessage(_ client: BridgeClient, message: BridgeMessage) {
        switch message {
        case .connected(let payload):
            connectionStatus = .connected(cmuxConnected: payload.cmuxConnected)
        case .notificationCreated(let n):
            notifications.insert(n, at: 0)
        case .notificationCleared:
            notifications = []
        case .cmuxConnected:
            connectionStatus = .connected(cmuxConnected: true)
        case .cmuxDisconnected:
            connectionStatus = .connected(cmuxConnected: false)
        case .commandResponse:
            break // handled via completion callbacks in BridgeClient
        }
    }
}

// MARK: - BridgeDiscoveryDelegate

extension AppState: BridgeDiscoveryDelegate {
    func discovery(_ discovery: BridgeDiscovery, didFind candidates: [PairingCredentials]) {
        // Auto-connect if we have a stored token that matches one of the discovered bridges,
        // or surface the picker if multiple are found and we're not already connected.
        guard connectionStatus == .disconnected,
              let stored = try? pairingStore.load() else { return }
        if let match = candidates.first(where: { $0.host == stored.host && $0.port == stored.port }) {
            connect(to: PairingCredentials(host: match.host, port: match.port, token: stored.token))
        }
    }
}

// MARK: - Models

struct BridgeNotification: Identifiable, Decodable {
    let id: String
    let title: String
    let subtitle: String?
    let body: String?
    let tabID: String?
    let panelID: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, body
        case tabID = "tab_id"
        case panelID = "panel_id"
        case createdAt = "created_at"
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
    let workspaceID: String?

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        self.title = (dict["title"] as? String) ?? (dict["type"] as? String) ?? id
        self.workspaceID = dict["workspace_id"] as? String
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
