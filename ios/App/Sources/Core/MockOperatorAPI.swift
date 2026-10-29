import Foundation
import AgentGateway

/// In-memory stand-in for the gateway, enabled with the `hermes_use_mock`
/// UserDefaults flag so the Hermes screen and voice tools can be exercised
/// without a reachable gateway. Mention "slow" in a message to simulate a
/// long-running agent reply.
@MainActor
final class MockOperatorAPI: OperatorAPI {
    var onStateChange: ((GatewayConnectionState) -> Void)?
    var onAgentEvent: ((OperatorAgentEvent) -> Void)?

    private var sessions: [AgentSessionInfo] = [
        AgentSessionInfo(key: "agent:main:main", label: "main", status: "active",
                         updatedAt: Date(), lastMessage: "Ready when you are."),
        AgentSessionInfo(key: "agent:main:task-webapp", label: "webapp refactor", status: "idle",
                         updatedAt: Date().addingTimeInterval(-3600), lastMessage: "Tests are green.")
    ]

    func connect() {
        onStateChange?(.connecting)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.onStateChange?(.connected)
        }
    }

    func disconnect() { onStateChange?(.disconnected) }

    func ensureConnected() async throws {}

    func chatSend(sessionKey: String, text: String) async throws -> String {
        let runID = UUID().uuidString
        let slow = text.localizedCaseInsensitiveContains("slow")
        let reply = slow
            ? "That took a while, but here it is: the mock agent finished the long task you asked about."
            : "Mock Antigravity here — you said: \"\(text)\". All systems nominal."
        let canonical = sessionKey.hasPrefix("agent:") ? sessionKey : "agent:main:\(sessionKey)"
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: slow ? 20_000_000_000 : 700_000_000)
            var streamed = ""
            for word in reply.split(separator: " ") {
                streamed += (streamed.isEmpty ? "" : " ") + word
                self?.onAgentEvent?(.replyDelta(sessionKey: canonical, runID: runID,
                                                cumulative: streamed, delta: String(word)))
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            self?.onAgentEvent?(.replyFinal(sessionKey: canonical, runID: runID, text: reply))
        }
        return runID
    }

    func sessionsList() async throws -> [AgentSessionInfo] {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return sessions
    }

    func sessionMessages(sessionKey: String) async throws -> [HermesChatMessage] {
        return [
            HermesChatMessage(role: .hermes, text: "Session \(sessionKey) ready on Antigravity.")
        ]
    }

    func spawnTask(_ spec: TaskSpec) async throws -> String {
        try? await Task.sleep(nanoseconds: 400_000_000)
        let key = "agent:main:task-\(sessions.count + 1)"
        sessions.insert(AgentSessionInfo(key: key, label: spec.label ?? spec.prompt.prefix(24).description,
                                         status: "active", updatedAt: Date(),
                                         lastMessage: spec.prompt), at: 0)
        onAgentEvent?(.sessionsChanged)
        return key
    }

    func channelSend(channel: String, to: String, text: String) async throws {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
}
