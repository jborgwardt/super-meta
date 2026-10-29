import Foundation
import AgentGateway

// MARK: - Models

struct HermesChatMessage: Identifiable, Equatable, Sendable {
    enum Role: Sendable { case user, hermes, system }
    let id: UUID
    let role: Role
    var text: String
    let timestamp: Date

    init(role: Role, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.timestamp = Date()
    }
}

struct AgentSessionInfo: Identifiable, Equatable, Sendable {
    let key: String
    var label: String
    var status: String
    var updatedAt: Date?
    var lastMessage: String?

    var id: String { key }
}

struct TaskSpec: Sendable {
    var prompt: String
    var repo: String?
    var label: String?
}

enum OperatorAgentEvent: Sendable {
    /// Streaming reply progress. `cumulative` is the full assistant snapshot when
    /// the gateway sends one; `delta` is the incremental chunk (protocol v4).
    case replyDelta(sessionKey: String, runID: String?, cumulative: String?, delta: String?)
    case replyFinal(sessionKey: String, runID: String?, text: String)
    case replyFailed(sessionKey: String, runID: String?, message: String)
    case sessionsChanged
}

/// Canonical session keys look like `agent:main:main`; requests may use the raw
/// tail (`main`). Events carry the canonical form, so match either way.
func sessionKeysMatch(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    return a.hasSuffix(":" + b) || b.hasSuffix(":" + a)
}

// MARK: - Wire methods

/// Hermes backend JSON-RPC method names, isolated here so protocol drift only
/// touches this file. Verified against `hermes serve` (Hermes Agent 0.18.x).
enum OperatorMethod {
    static let sessionCreate = "session.create"
    static let sessionList = "session.list"
    static let sessionResume = "session.resume"
    static let promptSubmit = "prompt.submit"
    static let sessionInterrupt = "session.interrupt"
}

// MARK: - Protocol

/// The operator-side surface of the gateway: everything HermesService needs,
/// hidden behind a protocol so the UI and voice tools can run against a mock.
@MainActor
protocol OperatorAPI: AnyObject {
    var onStateChange: ((GatewayConnectionState) -> Void)? { get set }
    var onAgentEvent: ((OperatorAgentEvent) -> Void)? { get set }

    func connect()
    func disconnect()
    /// Connects if needed and waits for the handshake to finish.
    func ensureConnected() async throws
    /// Sends a chat message; returns the run id identifying the streamed reply.
    func chatSend(sessionKey: String, text: String) async throws -> String
    func sessionsList() async throws -> [AgentSessionInfo]
    func sessionMessages(sessionKey: String) async throws -> [HermesChatMessage]
    /// Creates a session and starts it on the task prompt; returns the session key.
    func spawnTask(_ spec: TaskSpec) async throws -> String
    func channelSend(channel: String, to: String, text: String) async throws
}

// MARK: - Antigravity Bridge API implementation

/// Delegates requests to the authenticated VPS Antigravity Bridge API.
@MainActor
final class HermesOperatorAPI: OperatorAPI {
    var onStateChange: ((GatewayConnectionState) -> Void)?
    var onAgentEvent: ((OperatorAgentEvent) -> Void)?

    /// Sentinel meaning "the current conversation" (as opposed to a stored id).
    static let activeSessionKey = "main"

    private let configProvider: () -> HermesConfig
    private var client: HermesHTTPClient?
    private var stateObservation: Task<Void, Never>?
    private var activeSessionID: String?

    init(configProvider: @escaping () -> HermesConfig) {
        self.configProvider = configProvider
    }

    func connect() {
        // Idempotent: a launch-time auto-connect and a scenePhase resync can race;
        // don't tear down a live/in-flight socket and orphan its requests.
        if let existing = client, existing.state == .connecting || existing.state == .connected {
            existing.updateConfig(configProvider())
            return
        }
        disconnect()
        activeSessionID = nil
        let client = HermesHTTPClient(config: configProvider())
        self.client = client
        stateObservation?.cancel()
        stateObservation = Task { @MainActor [weak self] in
            guard let self, let client = self.client else { return }
            for await state in client.$state.values {
                self.onStateChange?(state)
            }
        }
        client.connect()
    }

    func disconnect() {
        stateObservation?.cancel(); stateObservation = nil
        client?.disconnect()
        client = nil
        activeSessionID = nil
        onStateChange?(.disconnected)
    }

    func ensureConnected() async throws {
        if client == nil { connect() }
        guard let client else { throw GatewayError(code: "DISCONNECTED", message: "No Antigravity client") }
        client.updateConfig(configProvider())
        if client.state != .connected {
            if client.state == .disconnected { client.connect() }
            try await client.waitUntilConnected()
        }
    }

    func chatSend(sessionKey: String, text: String) async throws -> String {
        try await ensureConnected()
        let runID = UUID().uuidString
        let stableSessionKey = sessionKey == Self.activeSessionKey ? "metamod:voice" : sessionKey
        let client = try requireClient()
        let currentCfg = configProvider()
        client.updateConfig(currentCfg)
        let explicitSessionID: String? = (sessionKey != Self.activeSessionKey && !sessionKey.hasPrefix("metamod:")) ? sessionKey : activeSessionID
        Task { @MainActor [weak self] in
            do {
                let reply = try await client.chat(
                    text: text,
                    sessionID: explicitSessionID,
                    sessionKey: stableSessionKey,
                    instance: currentCfg.instance,
                    onJobSubmitted: { [weak self] jobID in
                        Task { @MainActor [weak self] in
                            self?.onAgentEvent?(.replyDelta(
                                sessionKey: runID,
                                runID: runID,
                                cumulative: "Running coding job \(jobID) on \(currentCfg.instance.title)…",
                                delta: nil
                            ))
                        }
                    }
                )
                self?.activeSessionID = reply.sessionID ?? explicitSessionID
                await Task.yield()
                self?.onAgentEvent?(.replyFinal(sessionKey: runID, runID: runID, text: reply.shortReport))
            } catch let error as GatewayError {
                self?.onAgentEvent?(.replyFailed(sessionKey: runID, runID: runID, message: error.message))
            } catch {
                self?.onAgentEvent?(.replyFailed(sessionKey: runID, runID: runID, message: error.localizedDescription))
            }
        }
        return runID
    }

    func sessionsList() async throws -> [AgentSessionInfo] {
        try await ensureConnected()
        let currentCfg = configProvider()
        let client = try requireClient()
        client.updateConfig(currentCfg)
        let entries = try await client.listSessions(instance: currentCfg.instance)
        return entries.compactMap { parseSession($0) }
    }

    func sessionMessages(sessionKey: String) async throws -> [HermesChatMessage] {
        try await ensureConnected()
        let rawMsgs = try await requireClient().fetchConversationMessages(id: sessionKey)
        return rawMsgs.compactMap { entry -> HermesChatMessage? in
            guard let content = (entry["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { return nil }
            let roleStr = (entry["role"] as? String ?? "assistant").lowercased()
            let role: HermesChatMessage.Role = roleStr == "user" ? .user : (roleStr == "system" ? .system : .hermes)
            return HermesChatMessage(role: role, text: content)
        }
    }

    func spawnTask(_ spec: TaskSpec) async throws -> String {
        var prompt = spec.prompt
        if let repo = spec.repo, !repo.isEmpty { prompt = "Repository: \(repo)\n\n" + prompt }
        let key = "metamod:task:\(UUID().uuidString)"
        let runID = try await chatSend(sessionKey: key, text: prompt)
        return runID
    }

    func channelSend(channel: String, to: String, text: String) async throws {
        _ = try await chatSend(
            sessionKey: Self.activeSessionKey,
            text: "Send this message to \(to) on \(channel), then confirm delivery: \(text)"
        )
    }

    // MARK: Parsing

    private func requireClient() throws -> HermesHTTPClient {
        guard let client else { throw GatewayError(code: "DISCONNECTED", message: "Not connected to Antigravity") }
        return client
    }

    private func parseSession(_ entry: [String: Any]) -> AgentSessionInfo? {
        guard let id = entry["id"] as? String else { return nil }
        let title = entry["title"] as? String ?? ""
        let preview = entry["preview"] as? String ?? ""
        let startedAt = (entry["updated_at"] as? Double) ?? (entry["updated_at"] as? Int).map(Double.init)
        let messageCount = (entry["message_count"] as? Int) ?? 0
        return AgentSessionInfo(
            key: id,
            label: !title.isEmpty ? title : (!preview.isEmpty ? String(preview.prefix(40)) : id),
            status: messageCount > 0 ? "\(messageCount) msgs" : "new",
            updatedAt: startedAt.map { Date(timeIntervalSince1970: $0) },
            lastMessage: preview.isEmpty ? nil : preview
        )
    }
}
