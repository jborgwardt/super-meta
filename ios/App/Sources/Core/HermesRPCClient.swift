import Foundation
import os.log
import AgentGateway

private let log = Logger(subsystem: "com.priyanshu.metamod", category: "HermesRPC")

/// Remote Antigravity execution instances selectable from the app.
enum AntigravityInstance: String, CaseIterable, Identifiable, Sendable {
    case desktopVoidMars = "desktop-void-mars"
    case macSolarAxis = "justins-macbook-pro-local-solar-axis"
    case vpsCLI = "vps-cli"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktopVoidMars: return "desktop-void-mars"
        case .macSolarAxis: return "justins-macbook-pro-local-solar-axis"
        case .vpsCLI: return "VPS (100.64.0.18)"
        }
    }

    var shortLabel: String {
        switch self {
        case .desktopVoidMars: return "desktop-void-mars"
        case .macSolarAxis: return "solar-axis (Mac)"
        case .vpsCLI: return "VPS CLI"
        }
    }

    var subtitle: String {
        switch self {
        case .desktopVoidMars: return "VPS Antigravity IDE · calm-franklin"
        case .macSolarAxis: return "MacBook Pro · 100.64.0.6"
        case .vpsCLI: return "VPS Headless CLI · /home/justin/workspace"
        }
    }

    var workspaceLabel: String {
        switch self {
        case .desktopVoidMars: return "calm-franklin"
        case .macSolarAxis: return "mac"
        case .vpsCLI: return "CLI Project"
        }
    }

    static func resolve(_ raw: String?) -> AntigravityInstance {
        let lower = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("solar-axis") || lower.contains("mac") || lower == "100.64.0.6" {
            return .macSolarAxis
        }
        if lower == "vps-cli" || lower == "vps (100.64.0.18)" || lower == "cli" {
            return .vpsCLI
        }
        return .desktopVoidMars
    }
}

/// Endpoint for the remote VPS Antigravity Bridge (`100.64.0.18:7195`).
/// Authenticates every request with a Bearer token and supports asynchronous
/// coding job submission (`POST /api/jobs`) and polling (`GET /api/jobs/<id>`).
struct HermesConfig: Sendable, Equatable {
    static let defaultHost = "100.64.0.18"
    static let defaultPort = 7195
    static let defaultToken = "agy_luqSV_bhUML8RMF4v0EjZHC_mqMZTRzSXi99s70nDKs"

    var host: String
    var port: Int
    var useTLS: Bool
    var token: String
    var instance: AntigravityInstance

    init(
        host: String = HermesConfig.defaultHost,
        port: Int = HermesConfig.defaultPort,
        useTLS: Bool = false,
        token: String = HermesConfig.defaultToken,
        instance: AntigravityInstance = .desktopVoidMars
    ) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.token = token
        self.instance = instance
    }

    var webSocketURL: URL? {
        var components = URLComponents()
        components.scheme = useTLS ? "wss" : "ws"
        components.host = host
        components.port = port
        components.path = "/api/ws"
        if !token.isEmpty { components.queryItems = [URLQueryItem(name: "token", value: token)] }
        return components.url
    }

    func apiURL(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = useTLS ? "https" : "http"
        components.host = host
        components.port = port
        if let qIndex = path.firstIndex(of: "?") {
            components.path = String(path[..<qIndex])
            components.percentEncodedQuery = String(path[path.index(after: qIndex)...])
        } else {
            components.path = path
        }
        return components.url
    }
}

struct HermesAPIReply: Sendable {
    let text: String
    let shortReport: String
    let sessionID: String?
    let jobID: String?

    init(text: String, shortReport: String? = nil, sessionID: String? = nil, jobID: String? = nil) {
        self.text = text
        self.shortReport = shortReport ?? text
        self.sessionID = sessionID
        self.jobID = jobID
    }
}

/// HTTP client for the VPS Antigravity Bridge (`100.64.0.18:7195`).
/// Uses Bearer token authentication and the `/api/jobs` submit + poll flow.
@MainActor
final class HermesHTTPClient: ObservableObject {
    @Published private(set) var state: GatewayConnectionState = .disconnected

    private(set) var config: HermesConfig
    private let session: URLSession
    private var connectTask: Task<Void, Never>?

    init(config: HermesConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func updateConfig(_ newConfig: HermesConfig) {
        self.config = newConfig
    }

    func connect() {
        guard state != .connecting, state != .connected else { return }
        guard !config.token.isEmpty else {
            state = .error("Antigravity Bridge token is missing.")
            return
        }
        state = .connecting
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.request(path: "/api/status", method: "GET")
                guard !Task.isCancelled else { return }
                self.state = .connected
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .error(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        state = .disconnected
    }

    func waitUntilConnected(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state {
            case .connected: return
            case let .error(message): throw GatewayError(code: "CONNECT_FAILED", message: message)
            case .waitingForPairing: throw GatewayError(code: "UNAUTHORIZED", message: "Antigravity Bridge rejected the Bearer token")
            case .disconnected, .connecting:
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw GatewayError(code: "TIMEOUT", message: "Antigravity Bridge connection timed out")
    }

    /// Submits an async coding job via `POST /api/jobs` and polls `GET /api/jobs/<id>` until completion.
    func chat(
        text: String,
        sessionID: String?,
        sessionKey: String,
        repo: String? = nil,
        instance: AntigravityInstance? = nil,
        onJobSubmitted: ((String) -> Void)? = nil
    ) async throws -> HermesAPIReply {
        let targetInstance = instance ?? config.instance
        var submitBody: [String: Any] = [
            "prompt": text,
            "message": text,
            "instance": targetInstance.rawValue
        ]
        if let sessionID, !sessionID.isEmpty, !sessionID.hasPrefix("metamod:") {
            submitBody["conversation_id"] = sessionID
        }
        if let repo, !repo.isEmpty {
            submitBody["repo"] = repo
        }

        let submitData = try await request(path: "/api/jobs", method: "POST", body: submitBody)
        guard let submitJSON = try JSONSerialization.jsonObject(with: submitData) as? [String: Any],
              let jobID = (submitJSON["job_id"] as? String) ?? ((submitJSON["job"] as? [String: Any])?["id"] as? String),
              !jobID.isEmpty else {
            throw GatewayError(code: "BAD_RESPONSE", message: "Antigravity Bridge did not return a job_id")
        }
        onJobSubmitted?(jobID)

        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let pollData = try await request(path: "/api/jobs/\(jobID)", method: "GET")
            guard let pollJSON = try JSONSerialization.jsonObject(with: pollData) as? [String: Any] else {
                continue
            }
            let status = (pollJSON["status"] as? String) ?? ((pollJSON["job"] as? [String: Any])?["status"] as? String) ?? "running"
            if status == "completed" {
                let reply = (pollJSON["reply"] as? String)
                    ?? ((pollJSON["job"] as? [String: Any])?["reply"] as? String)
                    ?? "Coding job completed."
                let shortReport = (pollJSON["short_report"] as? String)
                    ?? ((pollJSON["job"] as? [String: Any])?["short_report"] as? String)
                    ?? reply
                let convID = (pollJSON["conversation_id"] as? String)
                    ?? ((pollJSON["job"] as? [String: Any])?["conversation_id"] as? String)
                return HermesAPIReply(
                    text: reply,
                    shortReport: shortReport,
                    sessionID: convID,
                    jobID: jobID
                )
            } else if status == "failed" {
                let errMsg = (pollJSON["error"] as? String)
                    ?? ((pollJSON["job"] as? [String: Any])?["error"] as? String)
                    ?? "Antigravity coding job failed"
                throw GatewayError(code: "JOB_FAILED", message: errMsg)
            }
        }
        throw GatewayError(code: "TIMEOUT", message: "Antigravity job \(jobID) timed out after 10 minutes")
    }

    func listSessions(instance: AntigravityInstance? = nil) async throws -> [[String: Any]] {
        let targetInstance = instance ?? config.instance
        let encoded = targetInstance.rawValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? targetInstance.rawValue
        let data = try await request(path: "/api/conversations?instance=\(encoded)", method: "GET")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["conversations"] as? [[String: Any]])
            ?? (json?["sessions"] as? [[String: Any]])
            ?? (json?["data"] as? [[String: Any]])
            ?? []
    }

    func fetchConversationMessages(id: String) async throws -> [[String: Any]] {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let data = try await request(path: "/api/conversations/\(encoded)", method: "GET")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["messages"] as? [[String: Any]]) ?? []
    }

    private func request(
        path: String,
        method: String,
        body: [String: Any]? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        guard let url = config.apiURL(path: path) else {
            throw GatewayError(code: "INVALID_URL", message: "Invalid Antigravity API URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayError(code: "NO_RESPONSE", message: "Antigravity did not return an HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Antigravity API returned HTTP \(http.statusCode)"
            throw GatewayError(code: "HTTP_\(http.statusCode)", message: message)
        }
        return data
    }
}

/// A JSON-RPC 2.0 client for the Hermes backend WebSocket. Correlates responses
/// to requests by id and forwards server events (`message.delta`, `session.info`,
/// …) to a callback. Main-actor isolated so non-Sendable JSON payloads stay put.
@MainActor
final class HermesRPCClient: ObservableObject {
    @Published private(set) var state: GatewayConnectionState = .disconnected

    /// Fires for every JSON-RPC event notification (method == "event").
    var onEvent: ((_ type: String, _ sessionID: String?, _ payload: [String: Any]) -> Void)?

    private var config: HermesConfig
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    private struct PayloadBox: @unchecked Sendable { let values: [String: Any] }
    private var pending: [Int: CheckedContinuation<PayloadBox, Error>] = [:]
    private var nextID = 1

    init(config: HermesConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func update(config: HermesConfig) { self.config = config }

    func connect() {
        guard let url = config.webSocketURL else { state = .error("Invalid Hermes URL"); return }
        disconnect()
        state = .connecting
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(on: task)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failPending(GatewayError(code: "DISCONNECTED", message: "Hermes connection closed"))
        if state != .disconnected { state = .disconnected }
    }

    /// Waits until `gateway.ready` has arrived (or the socket errors/closes).
    func waitUntilConnected(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state {
            case .connected: return
            case let .error(message): throw GatewayError(code: "CONNECT_FAILED", message: message)
            case .waitingForPairing: throw GatewayError(code: "UNAUTHORIZED", message: "Hermes rejected the token")
            case .disconnected, .connecting:
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw GatewayError(code: "TIMEOUT", message: "Hermes connect timed out")
    }

    // MARK: Requests

    func request(method: String, params: [String: Any] = [:], timeout: TimeInterval = 60) async throws -> [String: Any] {
        guard task != nil else { throw GatewayError(code: "DISCONNECTED", message: "Not connected to Hermes") }
        let id = nextID
        nextID += 1
        let box: PayloadBox = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.pending.removeValue(forKey: id)?
                    .resume(throwing: GatewayError(code: "TIMEOUT", message: "\(method) timed out"))
            }
        }
        return box.values
    }

    private func failPending(_ error: GatewayError) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    // MARK: Receive

    private func receiveLoop(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === socket else { return }
                switch result {
                case let .success(message):
                    self.handle(message)
                    self.receiveLoop(on: socket)
                case let .failure(error):
                    self.handleFailure(error, socket: socket)
                }
            }
        }
    }

    private func handleFailure(_ error: Error, socket: URLSessionWebSocketTask) {
        // 4401 = token rejected; anything else is a generic drop.
        let unauthorized = socket.closeCode == URLSessionWebSocketTask.CloseCode(rawValue: 4401)
        task = nil
        failPending(GatewayError(code: "DISCONNECTED", message: "Hermes connection lost"))
        state = unauthorized ? .error("Hermes rejected the token — check it and try again.") : .error(error.localizedDescription)
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case let .string(s): text = s
        case let .data(d): text = String(decoding: d, as: UTF8.self)
        @unknown default: return
        }
        // Newline-delimited: a frame may carry more than one JSON object.
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            route(json)
        }
    }

    private func route(_ json: [String: Any]) {
        // Response: carries an id we're waiting on.
        if let id = json["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = json["error"] as? [String: Any] {
                let code = (error["code"] as? Int).map(String.init) ?? "ERROR"
                continuation.resume(throwing: GatewayError(code: code, message: error["message"] as? String ?? "Request failed"))
            } else {
                continuation.resume(returning: PayloadBox(values: json["result"] as? [String: Any] ?? [:]))
            }
            return
        }
        // Event notification.
        if (json["method"] as? String) == "event", let params = json["params"] as? [String: Any] {
            let type = params["type"] as? String ?? ""
            if type == "gateway.ready" {
                log.notice("connected to Hermes gateway")
                state = .connected
                return
            }
            onEvent?(type, params["session_id"] as? String, params["payload"] as? [String: Any] ?? [:])
        }
    }

    // MARK: Send

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(string)) { error in
            if let error { log.error("hermes send failed: \(error.localizedDescription)") }
        }
    }
}
