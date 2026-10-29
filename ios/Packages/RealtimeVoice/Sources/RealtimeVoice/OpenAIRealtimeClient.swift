import Foundation
import os.log

private let log = Logger(subsystem: "com.priyanshu.metamod", category: "RealtimeVoice")

/// Events surfaced from the OpenAI Realtime API, normalized for the app.
public enum RealtimeEvent: Sendable {
    case sessionCreated
    case sessionUpdated
    case userTranscript(String)        // input_audio_transcription
    case assistantTextDelta(String)    // response.audio_transcript.delta / response.text.delta
    case assistantAudioDelta(Data)     // response.audio.delta (PCM16 @ 24k), decoded from base64
    case responseCreated
    case responseDone
    case functionCall(name: String, callID: String, argumentsJSON: String)
    case error(String)
    case other(String)
}

/// A function the model may call. The parameter schema is carried as a JSON
/// string so the type stays Sendable.
public struct RealtimeTool: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public struct RealtimeConfig: Sendable {
    public var model: String
    public var voice: String
    public var instructions: String
    /// When true the model both listens and speaks; false = text only.
    public var audio: Bool
    public var tools: [RealtimeTool]

    public init(
        model: String = "gemini-3.8-live",
        voice: String = "Aoede",
        instructions: String = "You are a helpful assistant for someone wearing smart glasses. Keep replies brief and spoken-friendly.",
        audio: Bool = true,
        tools: [RealtimeTool] = []
    ) {
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.audio = audio
        self.tools = tools
    }
}

/// WebSocket client for the OpenAI Realtime API. Cross-platform (no audio I/O here —
/// see `RealtimeAudioEngine` for capture/playback). Exposes a normalized event stream.
public final class OpenAIRealtimeClient: RealtimeClient, @unchecked Sendable {
    private let apiKey: String
    private let config: RealtimeConfig
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    private var continuation: AsyncStream<RealtimeEvent>.Continuation?
    public let events: AsyncStream<RealtimeEvent>

    public init(apiKey: String, config: RealtimeConfig = .init(), session: URLSession = .shared) {
        self.apiKey = apiKey
        self.config = config
        self.session = session
        var cont: AsyncStream<RealtimeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func connect() {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(config.model)")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop()
        sendSessionUpdate()
    }

    public func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.finish()
    }

    // MARK: Outgoing

    func sessionUpdateObject() -> [String: Any] {
        // GA Realtime API schema: session.type = "realtime", output_modalities,
        // nested audio { format, voice }, turn_detection.
        var sessionObj: [String: Any] = [
            "type": "realtime",
            "instructions": config.instructions,
            "output_modalities": config.audio ? ["audio"] : ["text"]
        ]
        if config.audio {
            sessionObj["audio"] = ["format": "pcm16", "voice": config.voice]
            sessionObj["turn_detection"] = ["type": "server_vad"]
        }
        if !config.tools.isEmpty {
            sessionObj["tools"] = config.tools.map { tool -> [String: Any] in
                let parameters = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) ?? [:]
                return ["type": "function", "name": tool.name, "description": tool.description, "parameters": parameters]
            }
            sessionObj["tool_choice"] = "auto"
        }
        return sessionObj
    }

    private func sendSessionUpdate() {
        send(["type": "session.update", "session": sessionUpdateObject()])
    }

    /// Return a tool result to the model. Follow with `createResponse()` once no
    /// other response is in flight so the model can speak about the outcome.
    public func sendFunctionOutput(callID: String, output: String) {
        send([
            "type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": callID, "output": output]
        ])
    }

    public func createResponse() {
        send(["type": "response.create"])
    }

    /// Append a chunk of PCM16 mic audio (base64-encoded internally).
    public func appendAudio(_ pcm16: Data) {
        send(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()])
    }

    /// Send a text turn and request a response.
    public func sendText(_ text: String) {
        send([
            "type": "conversation.item.create",
            "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]
        ])
        send(["type": "response.create"])
    }

    /// Attach an image frame (base64 JPEG) as visual context for the next turn.
    public func sendImage(_ jpeg: Data, note: String = "") {
        var content: [[String: Any]] = [["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]]
        if !note.isEmpty { content.append(["type": "input_text", "text": note]) }
        send([
            "type": "conversation.item.create",
            "item": ["type": "message", "role": "user", "content": content]
        ])
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(string)) { error in
            if let error { log.error("realtime send failed: \(error.localizedDescription)") }
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
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "session.created": continuation?.yield(.sessionCreated)
        case "session.updated": continuation?.yield(.sessionUpdated)
        case "response.audio.delta":
            if let b64 = json["delta"] as? String, let audio = Data(base64Encoded: b64) {
                continuation?.yield(.assistantAudioDelta(audio))
            }
        case "response.audio_transcript.delta", "response.text.delta":
            if let delta = json["delta"] as? String { continuation?.yield(.assistantTextDelta(delta)) }
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String { continuation?.yield(.userTranscript(transcript)) }
        case "response.created":
            continuation?.yield(.responseCreated)
        case "response.done":
            continuation?.yield(.responseDone)
        case "response.function_call_arguments.done":
            continuation?.yield(.functionCall(
                name: json["name"] as? String ?? "",
                callID: json["call_id"] as? String ?? "",
                argumentsJSON: json["arguments"] as? String ?? "{}"))
        case "error":
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "unknown realtime error"
            continuation?.yield(.error(msg))
        default:
            continuation?.yield(.other(type))
        }
    }
}
