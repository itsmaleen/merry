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

        if let completion {
            completions[id] = completion
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let task else { return }

        task.send(.string(String(data: data, encoding: .utf8)!)) { _ in }
    }

    // MARK: - Private

    private func startConnection() {
        let urlString = "ws://\(credentials.host):\(credentials.port)/ws"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")

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

        // Dispatch command responses to completions
        if let id = json["id"] as? String,
           let completion = completions.removeValue(forKey: id),
           let result = json["result"] as? [String: Any] {
            Task { @MainActor in completion(result) }
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
        Task { @MainActor in
            self.delegate?.clientDidDisconnect(self, error: error)
        }
        guard shouldReconnect else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let delay = backoff
        backoff = min(backoff * 2, 30)
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
