import CryptoKit
import Foundation

struct SocketIncomingMessage: Identifiable {
    let id: UUID
    let channelId: UUID
    let sessionKey: String
    let text: String
    let senderName: String
    let isFromUser: Bool
    let urgent: Bool
    let timestamp: Date
    let remoteMessageKey: String?
    let isHistory: Bool
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

    private typealias JSONObject = [String: Any]

    private struct GatewayResponse {
        let ok: Bool
        let payload: Any?
        let error: Any?
    }

    private struct StreamBuffer {
        var sessionKey: String
        var channelId: UUID
        var senderName: String
        var text: String
        var timestamp: Date
        var remoteMessageKey: String?
        var urgent: Bool
    }

    private enum GatewayError: LocalizedError {
        case invalidURL
        case notConnected
        case invalidFrame
        case invalidHandshake
        case server(message: String)
        case disconnected

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                "Invalid gateway URL"
            case .notConnected:
                "WebSocket not connected"
            case .invalidFrame:
                "Invalid gateway frame"
            case .invalidHandshake:
                "Gateway handshake failed"
            case .server(let message):
                message
            case .disconnected:
                "Connection closed"
            }
        }
    }

    private var gatewayURL = "ws://host:18789"
    private var gatewayToken = ""
    private var defaultSessionKey = "agent:main:main"

    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private var hasSentConnectRequest = false
    private var tickIntervalMs = 15_000
    private var tickMethodSupported = true

    private var pendingRequests: [String: CheckedContinuation<GatewayResponse, Error>] = [:]
    private var streamBuffers: [String: StreamBuffer] = [:]
    private var runChannelMap: [String: UUID] = [:]
    private var runSessionMap: [String: String] = [:]
    private var sessionChannelMap: [String: UUID] = [:]
    private var historyLoadedForChannel: Set<UUID> = []

    private var activeChannelId: UUID?
    private var activeSessionKey: String?

    func connect(to urlString: String, token: String = "", defaultSessionKey: String = "agent:main:main") {
        let normalizedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedURL.hasPrefix("ws://") || normalizedURL.hasPrefix("wss://") else {
            errorMessage = "Gateway URL must start with ws:// or wss://"
            connectionState = .failed
            return
        }

        let normalizedSessionKey = normalizeSessionKey(defaultSessionKey)
        let previousURL = gatewayURL
        let previousToken = gatewayToken
        let previousSessionKey = self.defaultSessionKey

        gatewayURL = normalizedURL
        gatewayToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultSessionKey = normalizedSessionKey
        activeSessionKey = activeSessionKey ?? normalizedSessionKey
        shouldReconnect = true

        let mustReconnect = connectionState != .connected
            || previousURL != gatewayURL
            || previousToken != gatewayToken
            || previousSessionKey != self.defaultSessionKey

        guard mustReconnect else { return }

        Task {
            await establishConnection()
        }
    }

    func setActiveChannel(_ channelId: UUID, sessionKey: String? = nil) {
        activeChannelId = channelId
        let resolvedSessionKey = resolveSessionKey(sessionKey)
        activeSessionKey = resolvedSessionKey
        sessionChannelMap[resolvedSessionKey] = channelId
    }

    func updateDefaultSessionKey(_ sessionKey: String) {
        defaultSessionKey = normalizeSessionKey(sessionKey)
        activeSessionKey = activeSessionKey ?? defaultSessionKey
    }

    func send(text: String, to channelId: UUID, senderName: String = "You", sessionKey: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard connectionState == .connected else {
            errorMessage = "WebSocket not connected"
            return
        }

        let resolvedSessionKey = resolveSessionKey(sessionKey)
        activeChannelId = channelId
        activeSessionKey = resolvedSessionKey
        sessionChannelMap[resolvedSessionKey] = channelId

        Task {
            do {
                let payload = try await sendRequest(
                    method: "chat.send",
                    params: [
                        "sessionKey": resolvedSessionKey,
                        "text": trimmed,
                        "idempotencyKey": UUID().uuidString
                    ]
                )

                if let response = payload as? JSONObject,
                   let runId = stringValue(response["runId"])
                {
                    runChannelMap[runId] = channelId
                    runSessionMap[runId] = resolvedSessionKey
                }
            } catch {
                errorMessage = "Send failed: \(error.localizedDescription)"
            }
        }
    }

    func loadHistory(
        for channelId: UUID,
        sessionKey: String? = nil,
        limit: Int = 50,
        force: Bool = false
    ) {
        let resolvedSessionKey = resolveSessionKey(sessionKey)
        sessionChannelMap[resolvedSessionKey] = channelId
        activeChannelId = channelId
        activeSessionKey = resolvedSessionKey

        if !force, historyLoadedForChannel.contains(channelId) {
            return
        }
        guard connectionState == .connected else {
            return
        }

        historyLoadedForChannel.insert(channelId)

        Task {
            do {
                let payload = try await sendRequest(
                    method: "chat.history",
                    params: [
                        "sessionKey": resolvedSessionKey,
                        "limit": max(1, limit)
                    ]
                )
                ingestHistory(payload, channelId: channelId, fallbackSessionKey: resolvedSessionKey)
            } catch {
                historyLoadedForChannel.remove(channelId)
                errorMessage = "History failed: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownConnection(closeCode: .normalClosure)
        connectionState = .disconnected
        errorMessage = nil
    }

    private func establishConnection() async {
        guard let url = URL(string: gatewayURL) else {
            errorMessage = GatewayError.invalidURL.localizedDescription
            connectionState = .failed
            return
        }

        teardownConnection(closeCode: .goingAway)

        hasSentConnectRequest = false
        tickMethodSupported = true
        streamBuffers.removeAll()
        runChannelMap.removeAll()
        runSessionMap.removeAll()
        historyLoadedForChannel.removeAll()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60

        session = URLSession(configuration: config)
        guard let session else {
            errorMessage = "Unable to create URLSession"
            connectionState = .failed
            return
        }

        let socketTask = session.webSocketTask(with: url)
        webSocketTask = socketTask
        connectionState = .connecting
        errorMessage = nil

        socketTask.resume()
        startReceiveLoop()
    }

    private func teardownConnection(closeCode: URLSessionWebSocketTask.CloseCode) {
        connectTask?.cancel()
        connectTask = nil

        tickTask?.cancel()
        tickTask = nil

        receiveTask?.cancel()
        receiveTask = nil

        failPendingRequests(with: GatewayError.disconnected)

        if let webSocketTask {
            webSocketTask.cancel(with: closeCode, reason: nil)
        }
        webSocketTask = nil

        session?.invalidateAndCancel()
        session = nil
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let task = webSocketTask else {
                return
            }

            do {
                let event = try await task.receive()
                switch event {
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleIncomingText(text)
                    }
                case .string(let text):
                    handleIncomingText(text)
                @unknown default:
                    break
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                handleSocketFailure(error)
                return
            }
        }
    }

    private func handleIncomingText(_ text: String) {
        guard let frame = decodeJSONObject(from: text) else {
            return
        }

        guard let type = stringValue(frame["type"]) else {
            return
        }

        switch type {
        case "event":
            handleEventFrame(frame)
        case "res":
            handleResponseFrame(frame)
        default:
            break
        }
    }

    private func handleEventFrame(_ frame: JSONObject) {
        guard let eventName = stringValue(frame["event"]) else { return }
        let payload = frame["payload"] as? JSONObject

        switch eventName {
        case "connect.challenge":
            guard !hasSentConnectRequest else { return }
            hasSentConnectRequest = true
            connectTask?.cancel()
            connectTask = Task { [weak self] in
                await self?.performHandshake(challengePayload: payload)
            }
        case "chat":
            guard let payload else { return }
            handleChatEvent(payload)
        case "tick":
            break
        default:
            break
        }
    }

    private func handleResponseFrame(_ frame: JSONObject) {
        guard let id = stringValue(frame["id"]) else { return }

        let response = GatewayResponse(
            ok: boolValue(frame["ok"]) ?? false,
            payload: frame["payload"],
            error: frame["error"]
        )

        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            return
        }
        continuation.resume(returning: response)
    }

    private func performHandshake(challengePayload: JSONObject?) async {
        do {
            _ = challengePayload

            let payload = try await sendRequest(method: "connect", params: connectParams())
            guard let hello = payload as? JSONObject else {
                throw GatewayError.invalidHandshake
            }

            guard stringValue(hello["type"]) == "hello-ok" else {
                throw GatewayError.invalidHandshake
            }

            if let policy = hello["policy"] as? JSONObject,
               let interval = intValue(policy["tickIntervalMs"])
            {
                tickIntervalMs = max(1_000, interval)
            } else {
                tickIntervalMs = 15_000
            }

            reconnectAttempt = 0
            connectionState = .connected
            errorMessage = nil

            startTickLoop()

            if let channelId = activeChannelId {
                loadHistory(
                    for: channelId,
                    sessionKey: activeSessionKey ?? defaultSessionKey,
                    limit: 50,
                    force: true
                )
            }
        } catch {
            connectionState = .failed
            errorMessage = "Handshake failed: \(error.localizedDescription)"
            scheduleReconnectIfNeeded()
        }
    }

    private func connectParams() -> JSONObject {
        [
            "minProtocol": 3,
            "maxProtocol": 3,
            "client": [
                "id": "openclaw-ios",
                "version": "0.1.0",
                "platform": "ios",
                "mode": "ui"
            ],
            "role": "operator",
            "scopes": ["operator.read", "operator.write"],
            "auth": [
                "token": gatewayToken
            ],
            "locale": "en-US",
            "userAgent": "claw-ios/0.1.0"
        ]
    }

    private func startTickLoop() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            await self?.tickLoop()
        }
    }

    private func tickLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(1_000, tickIntervalMs)) * 1_000_000)
            } catch {
                return
            }

            if Task.isCancelled { return }

            do {
                if tickMethodSupported {
                    do {
                        _ = try await sendRequest(
                            method: "tick",
                            params: ["ts": Int(Date().timeIntervalSince1970 * 1000)]
                        )
                    } catch {
                        let lowered = error.localizedDescription.lowercased()
                        if lowered.contains("unknown") || lowered.contains("not found") {
                            tickMethodSupported = false
                        }
                    }
                }

                try await sendPing()
            } catch {
                if Task.isCancelled { return }
                handleSocketFailure(error)
                return
            }
        }
    }

    private func sendPing() async throws {
        guard let task = webSocketTask else {
            throw GatewayError.notConnected
        }

        try await withCheckedThrowingContinuation { continuation in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func handleSocketFailure(_ error: Error) {
        tickTask?.cancel()
        tickTask = nil

        connectTask?.cancel()
        connectTask = nil

        failPendingRequests(with: error)

        if !Task.isCancelled {
            connectionState = .failed
            errorMessage = error.localizedDescription
        }

        if let webSocketTask {
            webSocketTask.cancel(with: .goingAway, reason: nil)
        }
        webSocketTask = nil

        session?.invalidateAndCancel()
        session = nil

        scheduleReconnectIfNeeded()
    }

    private func scheduleReconnectIfNeeded() {
        guard shouldReconnect else {
            connectionState = .disconnected
            return
        }

        reconnectTask?.cancel()

        let delaySeconds = min(Int(pow(2.0, Double(reconnectAttempt))), 30)
        reconnectAttempt += 1

        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            } catch {
                return
            }

            guard let self else { return }
            await self.establishConnection()
        }
    }

    private func sendRequest(method: String, params: JSONObject? = nil) async throws -> Any? {
        guard webSocketTask != nil, connectionState == .connected || method == "connect" else {
            throw GatewayError.notConnected
        }

        let requestID = UUID().uuidString
        var frame: JSONObject = [
            "type": "req",
            "id": requestID,
            "method": method
        ]
        if let params {
            frame["params"] = params
        }

        let response: GatewayResponse = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation

            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.resume(throwing: GatewayError.disconnected)
                    return
                }

                do {
                    try await self.sendFrame(frame)
                } catch {
                    if let pending = self.pendingRequests.removeValue(forKey: requestID) {
                        pending.resume(throwing: error)
                    }
                }
            }
        }

        guard response.ok else {
            throw GatewayError.server(message: gatewayErrorMessage(from: response.error))
        }

        return response.payload
    }

    private func sendFrame(_ frame: JSONObject) async throws {
        guard let task = webSocketTask else {
            throw GatewayError.notConnected
        }

        let data = try JSONSerialization.data(withJSONObject: frame, options: [])
        guard let text = String(data: data, encoding: .utf8) else {
            throw GatewayError.invalidFrame
        }

        try await task.send(.string(text))
    }

    private func failPendingRequests(with error: Error) {
        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func handleChatEvent(_ payload: JSONObject) {
        var flattened = payload
        if let nested = payload["message"] as? JSONObject {
            for (key, value) in nested where flattened[key] == nil {
                flattened[key] = value
            }
        }

        let runId = stringValue(flattened["runId"]) ?? stringValue(flattened["runID"])
        let sessionKey = resolveSessionKey(stringValue(flattened["sessionKey"]) ?? runId.flatMap { runSessionMap[$0] })
        if let runId {
            runSessionMap[runId] = sessionKey
        }

        let channelId = resolveChannelID(sessionKey: sessionKey, runId: runId)
        guard let channelId else { return }

        let role = (stringValue(flattened["role"]) ?? stringValue(flattened["authorRole"]) ?? "assistant").lowercased()
        let isFromUser = boolValue(flattened["isFromUser"])
            ?? boolValue(flattened["fromUser"])
            ?? ["user", "human", "operator"].contains(role)

        // We already persist local user sends optimistically.
        if isFromUser {
            return
        }

        let senderName = stringValue(flattened["senderName"]) ?? stringValue(flattened["sender"]) ?? "OpenClaw"
        let timestamp = dateValue(flattened["timestamp"])
            ?? dateValue(flattened["ts"])
            ?? dateValue(flattened["createdAt"])
            ?? .now
        let urgent = boolValue(flattened["urgent"])
            ?? (stringValue(flattened["priority"])?.lowercased() == "urgent")

        let deltaText = firstNonEmptyText([
            flattened["delta"],
            flattened["textDelta"],
            flattened["chunk"],
            flattened["token"],
            flattened["append"]
        ])

        let finalText = firstNonEmptyText([
            flattened["text"],
            flattened["content"],
            flattened["messageText"],
            flattened["finalText"],
            flattened["output"]
        ])

        let status = stringValue(flattened["status"])?.lowercased()
        let phase = stringValue(flattened["phase"])?.lowercased() ?? stringValue(flattened["type"])?.lowercased()
        let isComplete = boolValue(flattened["done"])
            ?? boolValue(flattened["final"])
            ?? boolValue(flattened["complete"])
            ?? boolValue(flattened["completed"])
            ?? ["done", "complete", "completed", "ok", "aborted", "error", "stopped"].contains(status ?? "")
            ?? ["done", "complete", "completed", "final", "end"].contains(phase ?? "")

        let streamKey = runId ?? "session:\(sessionKey)"
        var buffer = streamBuffers[streamKey] ?? StreamBuffer(
            sessionKey: sessionKey,
            channelId: channelId,
            senderName: senderName,
            text: "",
            timestamp: timestamp,
            remoteMessageKey: runId.map { "run:\(sessionKey):\($0)" },
            urgent: urgent
        )

        buffer.channelId = channelId
        buffer.timestamp = timestamp
        buffer.senderName = senderName
        buffer.urgent = urgent

        if let deltaText {
            buffer.text += deltaText
        }

        if let finalText, !finalText.isEmpty {
            if isComplete || finalText.count >= buffer.text.count {
                buffer.text = finalText
            } else if deltaText == nil {
                buffer.text += finalText
            }
        }

        streamBuffers[streamKey] = buffer

        guard isComplete else {
            return
        }

        streamBuffers.removeValue(forKey: streamKey)

        let finalizedText = buffer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalizedText.isEmpty else { return }

        emitIncoming(
            channelId: buffer.channelId,
            sessionKey: buffer.sessionKey,
            text: finalizedText,
            senderName: buffer.senderName,
            isFromUser: false,
            urgent: buffer.urgent,
            timestamp: buffer.timestamp,
            remoteMessageKey: buffer.remoteMessageKey,
            isHistory: false
        )
    }

    private func resolveChannelID(sessionKey: String, runId: String?) -> UUID? {
        if let runId, let mapped = runChannelMap[runId] {
            return mapped
        }
        if let mapped = sessionChannelMap[sessionKey] {
            return mapped
        }
        if let activeChannelId {
            sessionChannelMap[sessionKey] = activeChannelId
            return activeChannelId
        }
        return nil
    }

    private func ingestHistory(_ payload: Any?, channelId: UUID, fallbackSessionKey: String) {
        let entries = extractHistoryEntries(from: payload)
        guard !entries.isEmpty else { return }

        for entry in entries {
            guard let message = parseHistoryEntry(entry, channelId: channelId, fallbackSessionKey: fallbackSessionKey) else {
                continue
            }
            emitIncoming(message)
        }
    }

    private func extractHistoryEntries(from payload: Any?) -> [JSONObject] {
        if let list = payload as? [JSONObject] {
            return list
        }

        if let rawList = payload as? [Any] {
            return rawList.compactMap { $0 as? JSONObject }
        }

        guard let object = payload as? JSONObject else { return [] }

        for key in ["messages", "items", "entries", "history", "transcript"] {
            if let list = object[key] as? [JSONObject] {
                return list
            }
            if let rawList = object[key] as? [Any] {
                return rawList.compactMap { $0 as? JSONObject }
            }
        }

        return []
    }

    private func parseHistoryEntry(
        _ entry: JSONObject,
        channelId: UUID,
        fallbackSessionKey: String
    ) -> SocketIncomingMessage? {
        let text = firstNonEmptyText([
            entry["text"],
            entry["content"],
            entry["message"],
            entry["body"],
            entry["output"]
        ])?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let text, !text.isEmpty else {
            return nil
        }

        let role = (stringValue(entry["role"]) ?? stringValue(entry["authorRole"]) ?? "assistant").lowercased()
        let isFromUser = boolValue(entry["isFromUser"])
            ?? boolValue(entry["fromUser"])
            ?? ["user", "human", "operator"].contains(role)

        let sessionKey = resolveSessionKey(stringValue(entry["sessionKey"]) ?? fallbackSessionKey)
        let senderName = stringValue(entry["senderName"])
            ?? stringValue(entry["sender"])
            ?? (isFromUser ? "You" : "OpenClaw")

        let timestamp = dateValue(entry["timestamp"])
            ?? dateValue(entry["ts"])
            ?? dateValue(entry["createdAt"])
            ?? dateValue(entry["sentAt"])
            ?? .now

        let urgent = boolValue(entry["urgent"])
            ?? (stringValue(entry["priority"])?.lowercased() == "urgent")

        let remoteID = stringValue(entry["id"])
            ?? stringValue(entry["messageId"])
            ?? stringValue(entry["entryId"])
        let remoteMessageKey = remoteID.map { "history:\($0)" }
            ?? "history:\(stableDigest("\(sessionKey)|\(role)|\(timestamp.timeIntervalSince1970)|\(text)"))"

        return SocketIncomingMessage(
            id: UUID(),
            channelId: channelId,
            sessionKey: sessionKey,
            text: text,
            senderName: senderName,
            isFromUser: isFromUser,
            urgent: urgent,
            timestamp: timestamp,
            remoteMessageKey: remoteMessageKey,
            isHistory: true
        )
    }

    private func emitIncoming(
        channelId: UUID,
        sessionKey: String,
        text: String,
        senderName: String,
        isFromUser: Bool,
        urgent: Bool,
        timestamp: Date,
        remoteMessageKey: String?,
        isHistory: Bool
    ) {
        let incoming = SocketIncomingMessage(
            id: UUID(),
            channelId: channelId,
            sessionKey: sessionKey,
            text: text,
            senderName: senderName,
            isFromUser: isFromUser,
            urgent: urgent,
            timestamp: timestamp,
            remoteMessageKey: remoteMessageKey,
            isHistory: isHistory
        )

        emitIncoming(incoming)
    }

    private func emitIncoming(_ incoming: SocketIncomingMessage) {
        incomingMessages.append(incoming)
        if incomingMessages.count > 400 {
            incomingMessages.removeFirst(incomingMessages.count - 400)
        }
        onIncomingMessage?(incoming)
    }

    private func resolveSessionKey(_ provided: String?) -> String {
        normalizeSessionKey(provided ?? activeSessionKey ?? defaultSessionKey)
    }

    private func normalizeSessionKey(_ sessionKey: String) -> String {
        let trimmed = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "agent:main:main" : trimmed
    }

    private func decodeJSONObject(from text: String) -> JSONObject? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject
        else {
            return nil
        }
        return object
    }

    private func gatewayErrorMessage(from value: Any?) -> String {
        if let object = value as? JSONObject {
            if let message = stringValue(object["message"]), !message.isEmpty {
                return message
            }
            if let reason = stringValue(object["reason"]), !reason.isEmpty {
                return reason
            }
            if let code = stringValue(object["code"]), !code.isEmpty {
                return code
            }
        }

        if let value = stringValue(value), !value.isEmpty {
            return value
        }

        return "Gateway request failed"
    }

    private func firstNonEmptyText(_ values: [Any?]) -> String? {
        for value in values {
            if let text = textValue(from: value), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private func textValue(from value: Any?) -> String? {
        if let text = value as? String {
            return text
        }

        if let object = value as? JSONObject {
            for key in ["text", "value", "content", "message"] {
                if let text = textValue(from: object[key]) {
                    return text
                }
            }
            return nil
        }

        if let list = value as? [Any] {
            let joined = list.compactMap { textValue(from: $0) }.joined()
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? CustomStringConvertible {
            return value.description
        }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? Int {
            return value != 0
        }
        if let value = value as? Double {
            return value != 0
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1", "yes", "y", "on":
                return true
            case "false", "0", "no", "n", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? Double {
            return Int(value)
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private func dateValue(_ value: Any?) -> Date? {
        if let int = intValue(value) {
            // Heuristic: values above ~1e12 are milliseconds.
            if int > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: TimeInterval(int) / 1000)
            }
            return Date(timeIntervalSince1970: TimeInterval(int))
        }

        if let string = value as? String {
            let iso8601 = ISO8601DateFormatter()
            if let parsed = iso8601.date(from: string) {
                return parsed
            }
        }

        return nil
    }

    private func stableDigest(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
