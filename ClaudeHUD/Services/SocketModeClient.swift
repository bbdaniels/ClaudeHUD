import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "SocketMode")

// MARK: - Errors

enum SocketModeError: LocalizedError {
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let reason):
            return "apps.connections.open failed: \(reason)"
        }
    }
}

// MARK: - Socket Mode Client

/// Native Slack Socket Mode client over `URLSessionWebSocketTask`.
///
/// Slack Socket Mode (https://api.slack.com/apis/socket-mode):
/// 1. POST `apps.connections.open` with the app-level token to obtain a
///    short-lived `wss://` URL.
/// 2. Connect a WebSocket to that URL and read JSON envelopes.
/// 3. Each `events_api`/`slash_commands`/`interactive` envelope carries an
///    `envelope_id` that MUST be acked within 3 seconds by sending back a
///    `{"envelope_id": "<id>"}` text frame, or Slack retries delivery.
/// 4. Slack rotates the socket roughly every few minutes by sending a
///    `disconnect` envelope; the client must seamlessly re-open a new one.
///
/// The client is an `actor` so its socket state is serialized; the inbound
/// event handler is `@Sendable` and receives the raw JSON of the Events API
/// `event` object as `Data` (Sendable), which `SlackService` decodes on the
/// main actor. A process activity assertion keeps the socket warm even when
/// the menubar app has no visible window (App Nap would otherwise suspend it).
actor SocketModeClient {
    private let appToken: String
    private let session: URLSession

    private var onEvent: (@Sendable (Data) -> Void)?
    private var onSlashCommand: (@Sendable (Data) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var running = false
    private var activityToken: (any NSObjectProtocol)?
    private var backoff: TimeInterval = 1

    init(appToken: String) {
        self.appToken = appToken
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 0 // long-lived websocket
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    /// Set the handler invoked for each inbound Events API `event` object
    /// (passed as its JSON `Data`). Must be set before `start()`.
    func setEventHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        self.onEvent = handler
    }

    /// Set the handler invoked for each inbound `slash_commands` payload
    /// (passed as its JSON `Data`). The envelope is acked BEFORE this fires.
    /// Must be set before `start()`.
    func setSlashCommandHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        self.onSlashCommand = handler
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        beginActivity()
        Task { await connectLoop() }
    }

    func stop() {
        running = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        endActivity()
    }

    // MARK: - Connect / reconnect loop

    private func connectLoop() async {
        while running {
            do {
                let wssURL = try await openSocketURL()
                backoff = 1 // reset after a successful open
                try await runSocket(url: wssURL)
                // `runSocket` returns normally on a `disconnect` envelope —
                // Slack's routine socket rotation — so reconnect immediately.
            } catch {
                guard running else { break }
                logger.error("Socket error: \(error.localizedDescription); reconnecting in \(self.backoff, format: .fixed(precision: 1))s")
                SlackFileLog.log("socket error: \(error.localizedDescription); reconnecting in \(String(format: "%.1f", backoff))s")
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    /// POST `apps.connections.open` and return the `wss://` endpoint.
    private func openSocketURL() async throws -> URL {
        var req = URLRequest(url: URL(string: "https://slack.com/api/apps.connections.open")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data()

        let (data, response) = try await session.data(for: req)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let ok = json["ok"] as? Bool == true
        SlackFileLog.log("apps.connections.open HTTP=\(httpStatus) ok=\(ok ? "Y" : "N")\(ok ? "" : " error=\(json["error"] as? String ?? "unknown")")")
        guard ok,
              let urlString = json["url"] as? String,
              let url = URL(string: urlString) else {
            throw SocketModeError.openFailed(json["error"] as? String ?? "unknown")
        }
        return url
    }

    /// Run the WebSocket receive loop until it errors, closes, or receives a
    /// `disconnect` envelope. Returns normally only on `disconnect` (so the
    /// caller reconnects immediately); throws on socket error/closure.
    private func runSocket(url: URL) async throws {
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            if socket === task { socket = nil }
        }

        while running {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                if try await handleFrame(text) { return }
            case .data(let data):
                if let text = String(data: data, encoding: .utf8),
                   try await handleFrame(text) { return }
            @unknown default:
                break
            }
        }
    }

    // MARK: - Frame handling

    /// Decode and dispatch one inbound text frame. Returns `true` when the
    /// frame is a `disconnect` envelope (caller should reconnect immediately).
    private func handleFrame(_ text: String) async -> Bool {
        guard let data = text.data(using: .utf8),
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = envelope["type"] as? String else {
            return false
        }

        switch type {
        case "hello":
            logger.info("Socket Mode connected (hello)")
            SlackFileLog.log("socket connected (hello)")

        case "disconnect":
            let reason = envelope["reason"] as? String ?? "unknown"
            logger.info("Socket Mode disconnect (\(reason)); re-opening")
            SlackFileLog.log("disconnect (\(reason)); reconnecting")
            return true

        case "events_api", "slash_commands", "interactive":
            // Ack first — Slack requires this within 3s or it retries.
            if let envelopeId = envelope["envelope_id"] as? String {
                await ack(envelopeId)
            }
            if type == "events_api",
               let payload = envelope["payload"] as? [String: Any],
               let event = payload["event"] as? [String: Any],
               let eventData = try? JSONSerialization.data(withJSONObject: event) {
                onEvent?(eventData)
            } else if type == "slash_commands",
                      let payload = envelope["payload"] as? [String: Any],
                      let payloadData = try? JSONSerialization.data(withJSONObject: payload) {
                onSlashCommand?(payloadData)
            } else {
                // Interactive payloads are acked but not acted on yet.
                logger.debug("Acked \(type) envelope (not processed)")
            }

        default:
            logger.debug("Ignoring envelope type: \(type)")
        }
        return false
    }

    /// Send the `{"envelope_id": "<id>"}` acknowledgement frame.
    private func ack(_ envelopeId: String) async {
        guard let socket else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["envelope_id": envelopeId]),
              let text = String(data: data, encoding: .utf8) else { return }
        do {
            try await socket.send(.string(text))
        } catch {
            logger.error("Ack send failed: \(error.localizedDescription)")
        }
    }

    // MARK: - App Nap / suspension guard

    private func beginActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.background, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "ClaudeHUD Slack socket"
        )
    }

    private func endActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }
}
