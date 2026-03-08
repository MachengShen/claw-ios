import Foundation

struct SocketIncomingMessage: Identifiable {
    let id: UUID
    let channelId: UUID
    let text: String
    let senderName: String
    let isFromUser: Bool
    let urgent: Bool
    let timestamp: Date
}

@MainActor
final class WebSocketManager: NSObject, ObservableObject {
    enum ConnectionState: String {
        case disconnected = "Disconnected"
        case connecting = "Connecting"
        case connected = "Connected"
        case failed = "Failed"

        var icon: String {
            switch self {
            case .disconnected: "wifi.slash"
            case .connecting: "wifi"
            case .connected: "wifi"
            case .failed: "wifi.exclamationmark"
            }
        }
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var errorMessage: String?
    @Published private(set) var incomingMessages: [SocketIncomingMessage] = []

    var onIncomingMessage: ((SocketIncomingMessage) -> Void)?

    private var gatewayURL: String = "ws://host:18789"
    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    func connect(to urlString: String) {
        let normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("ws://") || normalized.hasPrefix("wss://") else {
            errorMessage = "Gateway URL must start with ws:// or wss://"
            connectionState = .failed
            return
        }

        gatewayURL = normalized
        Task {
            await establishConnection()
        }
    }

    func send(text: String, to channelId: UUID, senderName: String = "You") {
        guard let task = webSocketTask, connectionState == .connected else {
            errorMessage = "WebSocket not connected"
            return
        }

        let payload = OutgoingPayload(
            type: "chat.message",
            channelId: channelId.uuidString,
            senderName: senderName,
            text: text
        )

        guard let data = try? JSONEncoder().encode(payload) else {
            errorMessage = "Failed to encode outbound message"
            return
        }

        task.send(.data(data)) { [weak self] error in
            Task { @MainActor in
                if let error = error {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        connectionState = .disconnected
    }

    private func establishConnection() async {
        guard let url = URL(string: gatewayURL) else {
            errorMessage = "Invalid gateway URL"
            connectionState = .failed
            return
        }

        disconnect()

        session = URLSession(configuration: .default)
        guard let session else {
            errorMessage = "Unable to create URLSession"
            connectionState = .failed
            return
        }

        let socketTask = session.webSocketTask(with: url)
        webSocketTask = socketTask
        connectionState = .connecting
        socketTask.resume()
        connectionState = .connected
        errorMessage = nil

        await listen()
    }

    private func listen() async {
        await MainActor.run { errorMessage = nil }
        receiveTask = Task { [weak self] in
            guard let self = self else { return }

            while true {
                guard let activeTask = self.webSocketTask else {
                    await MainActor.run { self.connectionState = .disconnected }
                    return
                }
                do {
                    let event = try await activeTask.receive()
                    switch event {
                    case .data(let data)?:
                        await self.handleIncoming(data: data)
                    case .string(let text)?:
                        if let data = text.data(using: .utf8) {
                            await self.handleIncoming(data: data)
                        }
                    default:
                        break
                    }
                } catch {
                    await MainActor.run {
                        self.connectionState = .failed
                        self.errorMessage = error.localizedDescription
                    }
                    break
                }
            }
        }
    }

    private func handleIncoming(data: Data) async {
        guard let payload = try? JSONDecoder().decode(IncomingPayload.self, from: data) else {
            return
        }
        guard let channelId = UUID(uuidString: payload.channelId) else {
            return
        }

        let incoming = SocketIncomingMessage(
            id: UUID(),
            channelId: channelId,
            text: payload.text,
            senderName: payload.senderName ?? "OpenClaw",
            isFromUser: payload.isFromUser ?? false,
            urgent: payload.urgent ?? false,
            timestamp: Date(timeIntervalSince1970: payload.timestamp ?? Date().timeIntervalSince1970)
        )

        await MainActor.run {
            incomingMessages.append(incoming)
            if incomingMessages.count > 200 {
                incomingMessages.removeFirst(incomingMessages.count - 200)
            }
            onIncomingMessage?(incoming)
        }
    }
}

private struct OutgoingPayload: Codable {
    let type: String
    let channelId: String
    let senderName: String
    let text: String
    let timestamp: Double

    init(type: String, channelId: String, senderName: String, text: String) {
        self.type = type
        self.channelId = channelId
        self.senderName = senderName
        self.text = text
        self.timestamp = Date().timeIntervalSince1970
    }
}

private struct IncomingPayload: Codable {
    let type: String?
    let channelId: String
    let text: String
    let senderName: String?
    let isFromUser: Bool?
    let urgent: Bool?
    let timestamp: Double?

    init(type: String? = nil, channelId: String, text: String, senderName: String? = nil, isFromUser: Bool? = nil, urgent: Bool? = nil, timestamp: Double? = nil) {
        self.type = type
        self.channelId = channelId
        self.text = text
        self.senderName = senderName
        self.isFromUser = isFromUser
        self.urgent = urgent
        self.timestamp = timestamp
    }
}
