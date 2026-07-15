import Foundation

// MARK: - Message types

enum BridgeMessage {
    case connected(ConnectedPayload)
    case notificationCreated(BridgeNotification)
    case notificationCleared
    case cmuxConnected
    case cmuxDisconnected
    case commandResponse(CommandResponse)
}

struct ConnectedPayload: Decodable {
    let bridgeVersion: String
    let cmuxConnected: Bool
    let protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case bridgeVersion = "bridge_version"
        case cmuxConnected = "cmux_connected"
        case protocolVersion = "protocol_version"
    }
}

struct CommandResponse {
    let id: String
    let ok: Bool
    let result: [String: Any]
    let error: CommandError?
}

struct CommandError {
    let code: String
    let message: String
}

// MARK: - Delegate

protocol BridgeClientDelegate: AnyObject {
    @MainActor func clientDidConnect(_ client: BridgeClient)
    @MainActor func clientDidDisconnect(_ client: BridgeClient, error: Error?)
    @MainActor func clientDidReceiveMessage(_ client: BridgeClient, message: BridgeMessage)
}

// MARK: - Client

final class BridgeClient: NSObject {
    let credentials: PairingCredentials
    weak var delegate: BridgeClientDelegate?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var completions: [String: ([String: Any]) -> Void] = [:]
    // `completions` is written from the caller (main actor) and read from the
    // URLSession receive queue, so all access must be serialized.
    private let completionsLock = NSLock()
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = true
    private var backoff: TimeInterval = 1

    init(credentials: PairingCredentials) {
        self.credentials = credentials
    }

    // MARK: - Public API

    func connect() {
        shouldReconnect = true
        startConnection()
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    func send(
        method: String,
        params: [String: Any],
        completion: (([String: Any]) -> Void)? = nil
    ) {
        let id = UUID().uuidString
        let payload: [String: Any] = ["id": id, "method": method, "params": params]

        // Serialize the payload and confirm we have a live socket *before*
        // registering the completion, so a failed send can't leak a callback
        // that will never fire.
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8),
              let task else { return }

        if let completion {
            completionsLock.lock()
            completions[id] = completion
            completionsLock.unlock()
        }

        task.send(.string(text)) { [weak self] error in
            guard error != nil, let self else { return }
            // The send failed — drop the pending completion so callers that
            // chain follow-up work (refreshSurfaces, etc.) aren't stranded.
            self.completionsLock.lock()
            self.completions.removeValue(forKey: id)
            self.completionsLock.unlock()
        }
    }

    // MARK: - Private

    /// Whether to try the tailscale host on next connection attempt.
    private var useTailscale = false

    private func startConnection() {
        let host: String
        if useTailscale, let tsHost = credentials.tailscaleHost, !tsHost.isEmpty {
            host = tsHost
        } else {
            host = credentials.host
        }

        let urlString = "ws://\(host):\(credentials.port)/ws"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = useTailscale ? 10 : 5

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveNext()
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveNext()
            case .failure:
                self.handleDisconnect(error: nil)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let bridgeMessage = parse(json: json)
        Task { @MainActor in
            self.delegate?.clientDidReceiveMessage(self, message: bridgeMessage)
        }

        // Dispatch command responses to completions. Fire the completion for
        // ANY response carrying a matching id — even an `ok:true` reply with no
        // `result` payload — otherwise chained follow-up work never runs and
        // the UI silently goes stale.
        if let id = json["id"] as? String {
            completionsLock.lock()
            let completion = completions.removeValue(forKey: id)
            completionsLock.unlock()
            if let completion {
                let result = json["result"] as? [String: Any] ?? [:]
                Task { @MainActor in completion(result) }
            }
        }
    }

    private func parse(json: [String: Any]) -> BridgeMessage {
        let type = json["type"] as? String ?? ""
        let data = json["data"] as? [String: Any] ?? [:]

        switch type {
        case "connected":
            if let payloadData = try? JSONSerialization.data(withJSONObject: data),
               let payload = try? JSONDecoder().decode(ConnectedPayload.self, from: payloadData) {
                return .connected(payload)
            }
        case "notification.created":
            if let notifData = try? JSONSerialization.data(withJSONObject: data),
               let notif = try? JSONDecoder().decode(BridgeNotification.self, from: notifData) {
                return .notificationCreated(notif)
            }
        case "notification.cleared":
            return .notificationCleared
        case "cmux.connected":
            return .cmuxConnected
        case "cmux.disconnected":
            return .cmuxDisconnected
        default:
            break
        }

        // Command response envelope
        if let id = json["id"] as? String {
            let ok = json["ok"] as? Bool ?? false
            let result = json["result"] as? [String: Any] ?? [:]
            var cmdError: CommandError?
            if let errDict = json["error"] as? [String: Any] {
                cmdError = CommandError(
                    code: errDict["code"] as? String ?? "",
                    message: errDict["message"] as? String ?? ""
                )
            }
            return .commandResponse(CommandResponse(id: id, ok: ok, result: result, error: cmdError))
        }

        return .notificationCleared // fallback
    }

    private func handleDisconnect(error: Error?) {
        task = nil
        // Drop any in-flight completions; their responses will never arrive.
        // A fresh connect re-issues refreshWorkspaces/Surfaces from scratch.
        completionsLock.lock()
        completions.removeAll()
        completionsLock.unlock()
        Task { @MainActor in
            self.delegate?.clientDidDisconnect(self, error: error)
        }
        guard shouldReconnect else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let delay = backoff
        backoff = min(backoff * 2, 30)

        // Alternate between LAN and Tailscale on each retry
        if credentials.tailscaleHost != nil {
            useTailscale.toggle()
        }

        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, self.shouldReconnect else { return }
            self.startConnection()
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension BridgeClient: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        backoff = 1
        useTailscale = false // Reset — LAN worked, prefer it next time
        Task { @MainActor in
            self.delegate?.clientDidConnect(self)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        handleDisconnect(error: nil)
    }
}
