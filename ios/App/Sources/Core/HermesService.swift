import Foundation
import SwiftUI
import AgentGateway

/// Link to Hermes Agent's authenticated API server. Gemini function calls are
/// delegated here; Hermes then owns execution of its configured tools.
@MainActor
final class HermesService: ObservableObject {
    @Published private(set) var state: GatewayConnectionState = .disconnected
    @Published private(set) var messages: [HermesChatMessage] = []
    @Published private(set) var sessions: [AgentSessionInfo] = []
    /// In-flight reply text for the focused session, streamed as it arrives.
    @Published private(set) var streamingReply = ""
    @Published var focusedSessionKey = HermesOperatorAPI.activeSessionKey

    // Endpoint config (non-secret in UserDefaults, token in Keychain).
    @Published var host: String { didSet { defaults.set(host, forKey: "hermes_host") } }
    @Published var port: Int { didSet { defaults.set(port, forKey: "hermes_port") } }
    @Published var useTLS: Bool { didSet { defaults.set(useTLS, forKey: "hermes_tls") } }
    @Published var selectedInstance: AntigravityInstance {
        didSet {
            guard oldValue != selectedInstance else { return }
            defaults.set(selectedInstance.rawValue, forKey: "antigravity_instance")
            focusedSessionKey = HermesOperatorAPI.activeSessionKey
            Task { @MainActor [weak self] in await self?.refreshSessions() }
        }
    }
    /// Whether Antigravity IDE handoff is enabled alongside direct `lab-exec`.
    /// When false, Gemini uses `lab_exec` directly for all code & host execution.
    @Published var antigravityEnabled: Bool {
        didSet {
            guard oldValue != antigravityEnabled else { return }
            defaults.set(antigravityEnabled, forKey: "antigravity_enabled")
            if antigravityEnabled { connect() }
        }
    }

    /// Fires with the full reply of a run whose voice-budgeted ask already gave
    /// up — the voice layer announces these late answers.
    var onLateReply: ((String) -> Void)?

    private let defaults = UserDefaults.standard
    private let api: OperatorAPI
    private struct ReplyBox: @unchecked Sendable { let text: String }
    private var pendingReplies: [String: CheckedContinuation<ReplyBox, Error>] = [:]
    /// Runs that outlived their voice budget; their finals go to `onLateReply`.
    private var lateReplyRuns: Set<String> = []
    /// Live gateway session handle of the in-flight `ask`, used to match its
    /// streamed reply events (which are keyed by that handle, not the UI focus).
    private var activeRunSessionID: String?

    var token: String {
        get { KeychainStore.get("hermes_token") ?? "" }
        set { KeychainStore.set(newValue, for: "hermes_token"); objectWillChange.send() }
    }

    /// Optional launch-time endpoint override (`HERMES_ENDPOINT=https://host:port#token=…`).
    private static let envEndpoint = ProcessInfo.processInfo.environment["HERMES_ENDPOINT"]
        .flatMap { HermesPairingView.parseEndpoint($0) }

    /// The endpoint to use, in priority order: launch override, user-paired Antigravity
    /// bridge, or bundled VPS Antigravity Bridge (`100.64.0.18:7195`).
    private static func resolvedConfig(_ defaults: UserDefaults) -> HermesConfig {
        let savedInstance = AntigravityInstance.resolve(defaults.string(forKey: "antigravity_instance"))
        if let env = envEndpoint {
            return HermesConfig(host: env.host, port: env.port, useTLS: env.tls, token: env.token ?? "", instance: savedInstance)
        }
        let bundledHost = (Bundle.main.object(forInfoDictionaryKey: "AntigravityBridgeHost") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledPortStr = (Bundle.main.object(forInfoDictionaryKey: "AntigravityBridgePort") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledToken = (Bundle.main.object(forInfoDictionaryKey: "AntigravityBridgeToken") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let defaultHost = (bundledHost?.isEmpty == false && bundledHost?.hasPrefix("$(") == false) ? bundledHost! : HermesConfig.defaultHost
        let defaultPort = bundledPortStr.flatMap(Int.init) ?? HermesConfig.defaultPort
        let defaultToken = (bundledToken?.isEmpty == false && bundledToken?.hasPrefix("$(") == false) ? bundledToken! : HermesConfig.defaultToken

        if let saved = KeychainStore.get("hermes_token"), !saved.isEmpty {
            let savedPort = defaults.integer(forKey: "hermes_port")
            return HermesConfig(
                host: defaults.string(forKey: "hermes_host") ?? defaultHost,
                port: savedPort == 0 ? defaultPort : savedPort,
                useTLS: defaults.bool(forKey: "hermes_tls"),
                token: saved,
                instance: savedInstance
            )
        }
        return HermesConfig(host: defaultHost, port: defaultPort, useTLS: false, token: defaultToken, instance: savedInstance)
    }

    var isConfigured: Bool {
        true
    }

    init(api: OperatorAPI? = nil) {
        // Migrate any retired or localhost Hermes config to the VPS Antigravity Bridge (100.64.0.18:7195).
        let currentHost = defaults.string(forKey: "hermes_host") ?? ""
        let currentPort = defaults.integer(forKey: "hermes_port")
        let currentToken = KeychainStore.get("hermes_token") ?? ""
        if currentHost.isEmpty
            || currentHost == "127.0.0.1"
            || currentHost == "totally-mime-specials-york.trycloudflare.com"
            || currentPort == 8642
            || !currentToken.hasPrefix("agy_") {
            defaults.set(HermesConfig.defaultHost, forKey: "hermes_host")
            defaults.set(HermesConfig.defaultPort, forKey: "hermes_port")
            defaults.set(false, forKey: "hermes_tls")
            KeychainStore.set(HermesConfig.defaultToken, for: "hermes_token")
        }
        if defaults.string(forKey: "antigravity_instance") == nil {
            defaults.set(AntigravityInstance.desktopVoidMars.rawValue, forKey: "antigravity_instance")
        }
        // Debug/managed launches can supply a complete endpoint once. Persist it
        // exactly like an in-app pairing so reconnects do not depend on a
        // development environment variable.
        if let env = Self.envEndpoint {
            defaults.set(env.host, forKey: "hermes_host")
            defaults.set(env.port, forKey: "hermes_port")
            defaults.set(env.tls, forKey: "hermes_tls")
            if let token = env.token, !token.isEmpty { KeychainStore.set(token, for: "hermes_token") }
        }
        let initial = Self.resolvedConfig(defaults)
        self.host = initial.host
        self.port = initial.port
        self.useTLS = initial.useTLS
        self.selectedInstance = initial.instance
        self.antigravityEnabled = defaults.object(forKey: "antigravity_enabled") as? Bool ?? true

        if let api {
            self.api = api
        } else if UserDefaults.standard.bool(forKey: "hermes_use_mock") {
            self.api = MockOperatorAPI()
        } else {
            let defaults = self.defaults
            self.api = HermesOperatorAPI { HermesService.resolvedConfig(defaults) }
        }
        self.api.onStateChange = { [weak self] in self?.state = $0 }
        self.api.onAgentEvent = { [weak self] in self?.handleAgentEvent($0) }

        // A paired endpoint connects right away so the link is live app-wide,
        // not only once the Hermes screen opens.
        if isConfigured && !UserDefaults.standard.bool(forKey: "hermes_use_mock") {
            Task { @MainActor [weak self] in self?.connect() }
        }
    }

    /// Whether the user asked for a live link (drives foreground resync).
    private var wantsConnection = false

    func connect() {
        wantsConnection = true
        guard state != .connected, state != .connecting else { return }
        api.connect()
    }

    func disconnect() {
        wantsConnection = false
        api.disconnect()
        failPendingReplies(GatewayError(code: "DISCONNECTED", message: "Gateway connection closed"))
    }

    /// Backgrounding suspends the socket; reconnect and refresh when we return.
    func resyncOnForeground() {
        guard wantsConnection else { return }
        if state != .connected, state != .connecting { api.connect() }
        Task { @MainActor [weak self] in await self?.refreshSessions() }
    }

    // MARK: Actions

    /// Sends a message to hermes and awaits the full reply (streamed into
    /// `streamingReply` along the way). On timeout the run keeps going; the reply
    /// still lands in the transcript and `onReplyFinal` when it arrives.
    @discardableResult
    func ask(_ text: String, sessionKey: String? = nil, timeout: TimeInterval = 120) async throws -> String {
        let runID = try await startRun(text, sessionKey: sessionKey)
        return try await awaitReply(runID: runID, timeout: timeout)
    }

    /// Voice variant of `ask`: waits only `budget` seconds, then returns nil and
    /// routes the eventual reply to `onLateReply` so it can be spoken when ready.
    func askWithBudget(_ text: String, sessionKey: String? = nil, budget: TimeInterval = 12) async throws -> String? {
        let runID = try await startRun(text, sessionKey: sessionKey)
        do {
            return try await awaitReply(runID: runID, timeout: budget)
        } catch let error as GatewayError where error.code == "TIMEOUT" {
            lateReplyRuns.insert(runID)
            return nil
        }
    }

    private func startRun(_ text: String, sessionKey: String?) async throws -> String {
        try await api.ensureConnected()
        let key = sessionKey ?? focusedSessionKey
        messages.append(HermesChatMessage(role: .user, text: text))
        streamingReply = ""
        // chatSend returns the live gateway session handle; reply events are
        // keyed by it, so track it for streaming/transcript matching.
        let runID = try await api.chatSend(sessionKey: key, text: text)
        activeRunSessionID = runID
        return runID
    }

    private func awaitReply(runID: String, timeout: TimeInterval) async throws -> String {
        let box: ReplyBox = try await withCheckedThrowingContinuation { continuation in
            pendingReplies[runID] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.pendingReplies.removeValue(forKey: runID)?
                    .resume(throwing: GatewayError(code: "TIMEOUT", message: "Antigravity is still working on it"))
            }
        }
        return box.text
    }

    /// Dispatches a new agent task (e.g. a coding job on Antigravity); returns the run ID
    /// and registers it in `lateReplyRuns` so `onLateReply` speaks the completion report.
    func spawnTask(prompt: String, repo: String? = nil, label: String? = nil) async throws -> String {
        try await api.ensureConnected()
        let runID = try await api.spawnTask(TaskSpec(prompt: prompt, repo: repo, label: label))
        activeRunSessionID = runID
        lateReplyRuns.insert(runID)
        messages.append(HermesChatMessage(role: .user, text: prompt))
        messages.append(HermesChatMessage(role: .system, text: "Coding job submitted to Antigravity · \(selectedInstance.title) (\(shortKey(runID)))"))
        Task { @MainActor [weak self] in await self?.refreshSessions() }
        return runID
    }

    /// Sends an outbound message through one of Antigravity's channels (telegram, whatsapp, …).
    func sendChannelMessage(channel: String, to: String, text: String) async throws {
        try await api.ensureConnected()
        try await api.channelSend(channel: channel, to: to, text: text)
        messages.append(HermesChatMessage(role: .system, text: "Sent via \(channel) to \(to)"))
    }

    func refreshSessions() async {
        guard let list = try? await api.sessionsList() else { return }
        sessions = list
    }

    func selectSession(_ session: AgentSessionInfo) async {
        focusedSessionKey = session.key
        if let loaded = try? await api.sessionMessages(sessionKey: session.key), !loaded.isEmpty {
            messages = loaded
        }
    }

    // MARK: Voice tool calls

    /// Dispatches a realtime function call from the voice model. Always returns a
    /// JSON string — errors included — so the model can verbalize the outcome.
    func handleToolCall(name: String, argumentsJSON: String) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        if name.hasPrefix("lab_") {
            let host = (args["host"] as? String) ?? "vps"
            if name == "lab_exec", let cmd = args["cmd"] as? String {
                messages.append(HermesChatMessage(role: .system, text: "[lab-exec · \(host)] $ \(cmd)"))
            } else if name == "lab_write", let path = args["path"] as? String {
                messages.append(HermesChatMessage(role: .system, text: "[lab-exec · \(host)] write \(path)"))
            }
            let result = await LabExecTools.executeTool(name: name, args: args)
            if let stdout = result["stdout"] as? String, !stdout.isEmpty {
                messages.append(HermesChatMessage(role: .hermes, text: String(stdout.prefix(600))))
            }
            return Self.toolJSON(result)
        }
        do {
            switch name {
            case "antigravity_execute", "hermes_execute":
                guard let task = args["task"] as? String, !task.isEmpty else {
                    return Self.toolJSON(["error": "Missing task"])
                }
                if let reply = try await askWithBudget(task, budget: 8) {
                    return Self.toolJSON(["reply": reply])
                }
                return Self.toolJSON([
                    "status": "working",
                    "instance": selectedInstance.title,
                    "note": "Antigravity (\(selectedInstance.title)) is working on the coding job. Tell the user you've started it and will speak the result as soon as it finishes."
                ])
            case "antigravity_ask", "hermes_ask":
                guard let question = args["question"] as? String, !question.isEmpty else {
                    return Self.toolJSON(["error": "Missing question"])
                }
                if let reply = try await askWithBudget(question, sessionKey: args["session_id"] as? String, budget: 8) {
                    return Self.toolJSON(["reply": reply])
                }
                return Self.toolJSON([
                    "status": "working",
                    "instance": selectedInstance.title,
                    "note": "Antigravity (\(selectedInstance.title)) is working on it. Tell the user you'll speak the answer when it's ready."
                ])
            case "antigravity_spawn_task", "hermes_spawn_task":
                guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
                    return Self.toolJSON(["error": "Missing prompt"])
                }
                let key = try await spawnTask(prompt: prompt, repo: args["repo"] as? String)
                return Self.toolJSON([
                    "status": "started",
                    "instance": selectedInstance.title,
                    "session": shortKey(key),
                    "note": "Coding job dispatched to Antigravity (\(selectedInstance.title)). Tell the user it's running and you will speak a short report when it finishes."
                ])
            case "antigravity_send_message", "hermes_send_message":
                guard let recipient = args["recipient"] as? String, !recipient.isEmpty,
                      let message = args["message"] as? String, !message.isEmpty else {
                    return Self.toolJSON(["error": "Missing recipient or message"])
                }
                let channel = args["channel"] as? String ?? "telegram"
                try await sendChannelMessage(channel: channel, to: recipient, text: message)
                return Self.toolJSON(["status": "sent", "channel": channel, "recipient": recipient])
            case "antigravity_sessions_status", "hermes_sessions_status":
                try await api.ensureConnected()
                await refreshSessions()
                let summary = sessions.map { session -> [String: Any] in
                    var entry: [String: Any] = ["session": session.label, "status": session.status]
                    if let last = session.lastMessage { entry["lastMessage"] = String(last.prefix(200)) }
                    return entry
                }
                return Self.toolJSON(["instance": selectedInstance.title, "sessions": summary])
            case "antigravity_switch_instance":
                let requested = args["instance"] as? String
                selectedInstance = AntigravityInstance.resolve(requested)
                return Self.toolJSON([
                    "status": "switched",
                    "instance": selectedInstance.title,
                    "workspace": selectedInstance.workspaceLabel
                ])
            default:
                return Self.toolJSON(["error": "Unknown tool \(name)"])
            }
        } catch let error as GatewayError {
            return Self.toolJSON(["error": error.message])
        } catch {
            return Self.toolJSON(["error": error.localizedDescription])
        }
    }

    private static func toolJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"error":"Failed to encode tool result"}"#
        }
        return string
    }

    // MARK: Events

    private func handleAgentEvent(_ event: OperatorAgentEvent) {
        switch event {
        case let .replyDelta(sessionKey, _, cumulative, delta):
            guard isActiveRun(sessionKey) else { return }
            if let cumulative {
                streamingReply = cumulative
            } else if let delta {
                streamingReply += delta
            }
        case let .replyFinal(sessionKey, runID, text):
            let reply = text.isEmpty ? streamingReply : text
            if isActiveRun(sessionKey) {
                streamingReply = ""
                messages.append(HermesChatMessage(role: .hermes, text: reply))
            }
            if let runID, let continuation = pendingReplies.removeValue(forKey: runID) {
                continuation.resume(returning: ReplyBox(text: reply))
            }
            if let runID, lateReplyRuns.remove(runID) != nil {
                onLateReply?(reply)
            }
        case let .replyFailed(sessionKey, runID, message):
            if isActiveRun(sessionKey) {
                streamingReply = ""
                messages.append(HermesChatMessage(role: .system, text: "Run failed: \(message)"))
            }
            if let runID, let continuation = pendingReplies.removeValue(forKey: runID) {
                continuation.resume(throwing: GatewayError(code: "RUN_FAILED", message: message))
            }
            if let runID, lateReplyRuns.remove(runID) != nil {
                onLateReply?("The Antigravity coding job failed: \(message)")
            }
        case .sessionsChanged:
            Task { @MainActor [weak self] in await self?.refreshSessions() }
        }
    }

    private func failPendingReplies(_ error: GatewayError) {
        let waiting = pendingReplies
        pendingReplies.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    private func isActiveRun(_ sessionKey: String) -> Bool {
        guard let active = activeRunSessionID else { return false }
        return sessionKey == active
    }

    private func shortKey(_ key: String) -> String {
        key.components(separatedBy: ":").last ?? key
    }
}
