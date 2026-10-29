import Foundation
import os.log

private let log = Logger(subsystem: "com.priyanshu.metamod", category: "GeminiLive")

/// WebSocket client for the Gemini Live API (BidiGenerateContent). Same event
/// interface as `OpenAIRealtimeClient` so `RealtimeSession` can drive either.
///
/// Wire format: mic audio in as PCM16 @ 16 kHz, model audio out as PCM16 @ 24 kHz.
/// Auth: the API key is passed as the `?key=` query param (works for AIza… keys and
/// the newer AQ… AI Studio keys alike).
public final class GeminiLiveClient: RealtimeClient, @unchecked Sendable {
    public static let defaultRelayURL = "ws://100.64.0.4:8796/ws/live"

    private let apiKey: String
    private let config: RealtimeConfig
    private let baseURL: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private let sendLock = NSLock()
    private var setupComplete = false
    private var pendingMessages: [[String: Any]] = []
    private let maxPendingMessageCount = 64

    private var continuation: AsyncStream<RealtimeEvent>.Continuation?
    public let events: AsyncStream<RealtimeEvent>

    private static let geminiVoices: Set<String> = ["Aoede", "Charon", "Fenrir", "Kore", "Puck", "Zephyr", "Orus", "Leda"]

    public init(
        apiKey: String,
        config: RealtimeConfig = .init(),
        baseURL: String = GeminiLiveClient.defaultRelayURL,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.config = config
        self.baseURL = baseURL
        self.session = session
        var cont: AsyncStream<RealtimeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func connect() {
        let encoded = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? apiKey
        let separator = baseURL.contains("?") ? "&" : "?"
        guard let url = URL(string: "\(baseURL)\(separator)key=\(encoded)") else {
            continuation?.yield(.error("Invalid Gemini Live URL")); return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        startPingLoop()
        receiveLoop()
        sendSetup()
    }

    public func disconnect() {
        pingTask?.cancel()
        pingTask = nil
        sendLock.lock()
        setupComplete = false
        pendingMessages.removeAll()
        sendLock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.finish()
    }

    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                self?.task?.sendPing { _ in }
            }
        }
    }

    // MARK: Outgoing

    private func sendSetup() {
        sendImmediately(Self.setupMessage(config: config))
    }

    static func setupMessage(config: RealtimeConfig) -> [String: Any] {
        let voice = Self.geminiVoices.contains(config.voice) ? config.voice : "Aoede"
        var setup: [String: Any] = [
            "model": "models/\(config.model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]]
            ],
            "systemInstruction": ["parts": [["text": Self.groundedInstructions(config.instructions)]]],
            // Enables the transcript stream the UI shows.
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any]()
        ]
        // Google Search is a built-in Live API tool (not a Hermes tool). Keeping it
        // in every voice session means time-sensitive questions work even when the
        // user's personal Hermes server is offline or intentionally disconnected.
        // Gemini's current WebSocket schema uses camelCase for this field.
        var tools: [[String: Any]] = [["googleSearch": [String: Any]()]]
        if !config.tools.isEmpty {
            let decls = config.tools.map { tool -> [String: Any] in
                let params = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) as? [String: Any] ?? [:]
                return ["name": tool.name, "description": tool.description, "parameters": params]
            }
            tools.append(["functionDeclarations": decls])
        }
        setup["tools"] = tools
        return ["setup": setup]
    }

    private static func groundedInstructions(_ instructions: String) -> String {
        """
        \(instructions)

        For current, factual, or online information, use Google Search before answering. Do not claim you cannot search the web.
        """
    }

    public func appendAudio(_ pcm16: Data) {
        sendAfterSetup(Self.audioMessage(pcm16))
    }

    public func sendImage(_ jpeg: Data, note: String = "") {
        sendAfterSetup(Self.imageMessage(jpeg))
        if !note.isEmpty {
            sendAfterSetup(Self.clientContentImageMessage(jpeg, note: note))
        }
    }

    public func sendText(_ text: String) {
        sendAfterSetup(Self.textMessage(text))
    }

    public func sendFunctionOutput(callID: String, output: String) {
        let responseObj = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? ["result": output]
        sendAfterSetup(Self.toolResponseMessage(callID: callID, response: responseObj))
    }

    // Gemini auto-responds after a tool_response / client_content turn, so there's
    // no explicit "create response" call.
    public func createResponse() {}

    static func audioMessage(_ pcm16: Data) -> [String: Any] {
        ["realtimeInput": ["audio": [
            "mimeType": "audio/pcm;rate=16000",
            "data": pcm16.base64EncodedString()
        ]]]
    }

    static func imageMessage(_ jpeg: Data) -> [String: Any] {
        ["realtimeInput": ["video": [
            "mimeType": "image/jpeg",
            "data": jpeg.base64EncodedString()
        ]]]
    }

    static func clientContentImageMessage(_ jpeg: Data, note: String) -> [String: Any] {
        [
            "clientContent": [
                "turns": [[
                    "role": "user",
                    "parts": [
                        ["inlineData": [
                            "mimeType": "image/jpeg",
                            "data": jpeg.base64EncodedString()
                        ]],
                        ["text": note]
                    ]
                ]],
                "turnComplete": true
            ]
        ]
    }

    static func textMessage(_ text: String) -> [String: Any] {
        ["realtimeInput": ["text": text]]
    }

    static func toolResponseMessage(callID: String, response: [String: Any]) -> [String: Any] {
        ["toolResponse": ["functionResponses": [[
            "id": callID,
            "response": response
        ]]]]
    }

    /// The Live API rejects any input sent before it acknowledges setup. Mic taps
    /// begin immediately, so hold those chunks until `setupComplete` arrives.
    private func sendAfterSetup(_ object: [String: Any]) {
        sendLock.lock()
        guard setupComplete else {
            // A rejected or stalled setup must not retain unbounded microphone data.
            if pendingMessages.count == maxPendingMessageCount { pendingMessages.removeFirst() }
            pendingMessages.append(object)
            sendLock.unlock()
            return
        }
        sendLock.unlock()
        sendImmediately(object)
    }

    private func flushPendingMessages() {
        sendLock.lock()
        setupComplete = true
        let pending = pendingMessages
        pendingMessages.removeAll()
        sendLock.unlock()
        pending.forEach(sendImmediately)
    }

    private func sendImmediately(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(string)) { error in
            if let error { log.error("gemini send failed: \(error.localizedDescription)") }
        }
    }

    // MARK: Incoming

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                self.handle(message)
                self.receiveLoop()
            case let .failure(error):
                self.continuation?.yield(.error(error.localizedDescription))
                self.continuation?.finish()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .string(s): data = Data(s.utf8)
        case let .data(d): data = d
        @unknown default: return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if json["setupComplete"] != nil {
            flushPendingMessages()
            continuation?.yield(.sessionCreated)
            return
        }

        if let server = json["serverContent"] as? [String: Any] {
            handleServerContent(server)
            return
        }

        if let toolCall = json["toolCall"] as? [String: Any] {
            let calls = toolCall["functionCalls"] as? [[String: Any]] ?? []
            for call in calls {
                let name = call["name"] as? String ?? ""
                let id = call["id"] as? String ?? name
                let args = call["args"] as? [String: Any] ?? [:]
                let argsJSON = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                continuation?.yield(.functionCall(name: name, callID: id, argumentsJSON: argsJSON))
            }
            return
        }

        if json["error"] != nil {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "Gemini Live error"
            continuation?.yield(.error(msg))
        }
    }

    private func handleServerContent(_ content: [String: Any]) {
        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                if let inline = part["inlineData"] as? [String: Any],
                   let b64 = inline["data"] as? String, let audio = Data(base64Encoded: b64) {
                    continuation?.yield(.assistantAudioDelta(audio))
                }
                if let text = part["text"] as? String,
                   !text.isEmpty,
                   (part["thought"] as? Bool) != true {
                    continuation?.yield(.assistantTextDelta(text))
                }
            }
        }
        if let out = content["outputTranscription"] as? [String: Any],
           let text = out["text"] as? String, !text.isEmpty {
            continuation?.yield(.assistantTextDelta(text))
        }
        if let inp = content["inputTranscription"] as? [String: Any],
           let text = inp["text"] as? String, !text.isEmpty {
            continuation?.yield(.userTranscript(text))
        }
        if content["turnComplete"] as? Bool == true {
            continuation?.yield(.responseDone)
        }
    }
}

private extension CharacterSet {
    /// Query-value safe set (excludes `&`, `=`, `+`, `?`, `/` etc. from the token).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?/")
        return set
    }()
}
