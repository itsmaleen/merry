import Foundation

/// Watches the paired devices the phone is NOT showing, so the grid can list
/// their sessions. One quiet connection per device, alive only while the grid
/// is open: it lists workspaces and surfaces every few seconds and subscribes
/// to nothing, so it never moves a device's focus or streams a screen.
@MainActor
final class DevicePeeker: ObservableObject {
    @Published private(set) var snapshots: [UUID: DeviceSnapshot] = [:]

    private var watchers: [UUID: Watcher] = [:]
    private var timer: Timer?
    private static let interval: TimeInterval = 10

    /// Watches exactly these devices. The last snapshot of a device that is
    /// still listed is kept, so reopening the grid shows it at once.
    func watch(_ bridges: [SavedBridge]) {
        let wanted = Set(bridges.map(\.id))
        for (id, watcher) in watchers where !wanted.contains(id) {
            watcher.stop()
            watchers[id] = nil
        }
        for id in snapshots.keys where !wanted.contains(id) { snapshots[id] = nil }
        for bridge in bridges where watchers[bridge.id] == nil {
            if snapshots[bridge.id] == nil { snapshots[bridge.id] = DeviceSnapshot() }
            let id = bridge.id
            let watcher = Watcher(credentials: bridge.credentials) { [weak self] reach, sessions in
                self?.apply(id, reach: reach, sessions: sessions)
            }
            watchers[id] = watcher
            watcher.start()
        }
        if watchers.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.watchers.values.forEach { $0.refresh() } }
            }
        }
    }

    /// Closes every connection; snapshots stay for the next open.
    func pause() {
        for watcher in watchers.values { watcher.stop() }
        watchers = [:]
        timer?.invalidate()
        timer = nil
    }

    /// Screenshot fixtures: snapshots with no connection behind them.
    func seed(_ fixtures: [UUID: DeviceSnapshot]) { snapshots = fixtures }

    private func apply(_ id: UUID, reach: DeviceSnapshot.Reach, sessions: [PeekSession]?) {
        guard watchers[id] != nil else { return }
        var snapshot = snapshots[id] ?? DeviceSnapshot()
        snapshot.reach = reach
        // An unreachable device keeps its last list, shown dimmed.
        if let sessions { snapshot.sessions = DeviceSnapshot.ordered(sessions) }
        if snapshots[id] != snapshot { snapshots[id] = snapshot }
    }
}

/// One device's connection. Reports (reach, sessions); sessions is nil when
/// only the reach changed.
@MainActor
private final class Watcher: BridgeClientDelegate {
    private let client: BridgeClient
    private let report: (DeviceSnapshot.Reach, [PeekSession]?) -> Void
    private var connected = false
    private var stopped = false
    private var generation = 0
    private var loadingSince: Date?
    /// Listing every workspace of a busy machine is not a glance.
    private static let maxWorkspaces = 12

    init(credentials: PairingCredentials, report: @escaping (DeviceSnapshot.Reach, [PeekSession]?) -> Void) {
        self.client = BridgeClient(credentials: credentials)
        self.report = report
    }

    func start() {
        client.delegate = self
        client.connect()
        // The client keeps retrying (LAN, then tailnet); say "offline" if
        // nothing has answered by then rather than spin forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.stopped, !self.connected else { return }
            self.report(.offline, nil)
        }
    }

    func stop() {
        stopped = true
        client.delegate = nil
        client.disconnect()
    }

    func refresh() {
        guard connected, !stopped else { return }
        // A reply that never comes must not block every later refresh.
        if let since = loadingSince, Date().timeIntervalSince(since) < 8 { return }
        loadingSince = Date()
        generation += 1
        let gen = generation
        client.send(method: "workspace.list", params: [:]) { [weak self] result in
            guard let self, gen == self.generation, !self.stopped else { return }
            let workspaces = ((result["workspaces"] as? [[String: Any]]) ?? [])
                .compactMap(Workspace.init)
                .prefix(Self.maxWorkspaces)
            guard !workspaces.isEmpty else {
                self.loadingSince = nil
                self.report(.online, [])
                return
            }
            var pending = workspaces.count
            var byWorkspace: [String: [PeekSession]] = [:]
            for workspace in workspaces {
                self.client.send(method: "surface.list", params: ["workspace_id": workspace.id]) { [weak self] result in
                    guard let self, gen == self.generation, !self.stopped else { return }
                    byWorkspace[workspace.id] = ((result["surfaces"] as? [[String: Any]]) ?? [])
                        .compactMap { PeekSession($0, workspaceTitle: workspace.title) }
                    pending -= 1
                    guard pending == 0 else { return }
                    self.loadingSince = nil
                    // Workspace order, then each workspace's own order.
                    self.report(.online, workspaces.flatMap { byWorkspace[$0.id] ?? [] })
                }
            }
        }
    }

    func clientDidConnect(_ client: BridgeClient) {
        guard !stopped else { return }
        connected = true
        loadingSince = nil
        refresh()
    }

    func clientDidDisconnect(_ client: BridgeClient, error: Error?) {
        guard !stopped else { return }
        connected = false
        loadingSince = nil
        report(.offline, nil)
    }

    func clientDidReceiveMessage(_ client: BridgeClient, message: BridgeMessage) {}
}
