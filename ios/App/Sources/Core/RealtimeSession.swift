import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import SwiftUI
import RealtimeVoice
import AIProviders
import GlassesKit

/// Drives a live realtime voice session: connects the Gemini Live client via the
/// Vertex AI Ultra relay, pumps mic audio up and model audio down through the shared
/// audio engine, surfaces transcripts, keeps the camera off unless explicitly requested,
/// and ends the session when the wearer taps-and-holds on the right side of the glasses.
@MainActor
final class RealtimeSession: ObservableObject {
    enum Status: Equatable { case idle, connecting, live, error(String) }

    @Published var status: Status = .idle
    @Published var transcript = ""
    @Published var userLine = ""

    /// Resolves a model function call to its JSON result (see `HermesService.handleToolCall`).
    var toolHandler: ((_ name: String, _ argumentsJSON: String) async -> String)?

    private var client: (any RealtimeClient)?
    private let audio = RealtimeAudioEngine.shared
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var eventTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var sessionStartedAt: Date = .distantPast
    private var interruptionObserver: NSObjectProtocol?
    private var remoteCommandRegistered = false

    private var providers: ProviderManager?
    private var glasses: GlassesService?

    /// Tracks whether the user explicitly asked to turn the glasses camera on.
    @Published private(set) var isCameraActive = false
    private var cameraStartedByUser = false {
        didSet { isCameraActive = cameraStartedByUser }
    }
    /// Monotonic counter of received assistant audio chunks (used by announcement watchdog).
    private var receivedAudioChunks = 0
    /// Temporarily suppresses hardware mic capture while streaming an autotest voice clip.
    nonisolated(unsafe) private var suppressMicCapture = false
    private var didRunAutotestClip = false

    /// The realtime API rejects response.create while a response is streaming,
    /// so tool outputs and announcements queue until the current one finishes.
    private var responseInFlight = false
    private var pendingResponseCreate = false
    private var announcementQueue: [String] = []

    init() {
        setupGlassesGestureHandling()
    }

    /// Wires up both Bluetooth AVRCP remote commands (`MPRemoteCommandCenter`) and
    /// HFP tap-and-hold audio interruptions (`AVAudioSession.interruptionNotification`)
    /// so tapping-and-holding on the right temple touchpad of the Meta glasses ends
    /// the active Live AI session hands-free, even while the iPhone is locked.
    private func setupGlassesGestureHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.status == .live || self.status == .connecting else { return }
                // Ignore any transient interruption within 1.0s of session start.
                guard Date().timeIntervalSince(self.sessionStartedAt) > 1.0 else { return }
                if type == .began {
                    print("[SuperMeta] Glasses right-side tap-and-hold / interruption detected — ending Live AI session")
                    fflush(stdout)
                    self.stop()
                }
            }
        }
    }

    private func activateRemoteControlForSession() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let cc = MPRemoteCommandCenter.shared()
        if !remoteCommandRegistered {
            remoteCommandRegistered = true
            let handler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.status == .live || self.status == .connecting else { return }
                    print("[SuperMeta] Glasses touchpad remote command detected — ending Live AI session")
                    fflush(stdout)
                    self.stop()
                }
                return .success
            }
            for cmd in [cc.togglePlayPauseCommand, cc.pauseCommand, cc.stopCommand, cc.playCommand, cc.nextTrackCommand] {
                cmd.isEnabled = true
                cmd.addTarget(handler: handler)
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Super Meta · Live AI",
            MPMediaItemPropertyArtist: "Gemini 3.8 Live · Antigravity",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
    }

    private func deactivateRemoteControlForSession() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Starts a session. Camera stays off unless `injectFrames` is true or requested by voice.
    func start(
        instructions: String,
        voice: String? = nil,
        providers: ProviderManager,
        glasses: GlassesService,
        injectFrames: Bool = false,
        tools: [RealtimeTool] = []
    ) {
        self.providers = providers
        self.glasses = glasses
        self.cameraStartedByUser = injectFrames
        let key = providers.realtimeAPIKey()
        guard !key.isEmpty else {
            status = .error("Add your Gemini API key in Settings for realtime voice.")
            return
        }
        status = .connecting
        sessionStartedAt = Date()
        transcript = ""
        userLine = ""
        responseInFlight = false
        pendingResponseCreate = false
        announcementQueue = []
        activateRemoteControlForSession()

        let selectedVoice = voice ?? providers.realtimeVoice
        let config = RealtimeConfig(model: providers.realtimeModel, voice: selectedVoice, instructions: instructions, audio: true, tools: tools)
        // Pause wake recognition while keeping the shared AVAudioEngine running so
        // starting Live AI while the iPhone is locked never fails with OSStatus 560557684.
        WakeWordListener.shared.pause { [weak self] in
            Task { @MainActor [weak self] in
                self?.beginGeminiLive(config: config, apiKey: key, injectFrames: injectFrames)
            }
        }
    }

    private func beginGeminiLive(config: RealtimeConfig, apiKey: String, injectFrames: Bool) {
        guard status == .connecting else { return }
        let relayURL = providers?.geminiRelayWebSocketURL() ?? GeminiLiveClient.defaultRelayURL
        print("[SuperMeta] Connecting GeminiLiveClient to \(relayURL) model=\(config.model)")
        fflush(stdout)
        let client: any RealtimeClient = GeminiLiveClient(apiKey: apiKey, config: config, baseURL: relayURL)
        self.client = client

        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.events {
                self.handle(event)
            }
        }

        do {
            try audio.start(captureSampleRate: 16_000) { [weak self, weak client] chunk in
                guard self?.suppressMicCapture != true else { return }
                client?.appendAudio(chunk)
            }
            client.connect()
            if injectFrames { startFrameInjection() }
        } catch {
            endWithError("Audio error: \(error.localizedDescription)")
        }
    }

    func stop() {
        frameTask?.cancel(); frameTask = nil
        eventTask?.cancel(); eventTask = nil
        if cameraStartedByUser, let glasses {
            cameraStartedByUser = false
            Task { await glasses.stopStreaming() }
        }
        deactivateRemoteControlForSession()
        audio.stop()
        client?.disconnect()
        client = nil
        status = .idle
        WakeWordListener.shared.resume()
    }

    /// Toggles the glasses camera on or off on explicit user action (button tap).
    func toggleCamera(glasses: GlassesService) async {
        self.glasses = glasses
        if cameraStartedByUser || glasses.isStreaming {
            cameraStartedByUser = false
            frameTask?.cancel()
            frameTask = nil
            await glasses.stopStreaming()
        } else {
            await glasses.startStreaming()
            if glasses.isStreaming {
                cameraStartedByUser = true
                if status == .live {
                    startFrameInjection()
                }
            }
        }
    }

    /// Snaps a single photo from the glasses camera on demand, sends it into the
    /// active Gemini Live session (if live), and stops the camera again unless
    /// continuous camera streaming was explicitly enabled.
    func snapAndSendFrame(glasses: GlassesService, prompt: String = "Describe what is in front of me right now in this fresh glasses camera snapshot.") async {
        self.glasses = glasses
        let keepCameraOn = glasses.isStreaming || cameraStartedByUser
        if !glasses.isStreaming {
            await glasses.startStreaming()
            for _ in 0..<12 {
                if glasses.currentFrameJPEG(maxWidth: 1280, quality: 0.75) != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let image: Data?
        if let latest = glasses.currentFrameJPEG(maxWidth: 1280, quality: 0.75) {
            image = latest
        } else {
            image = try? await glasses.capturePhoto()
        }
        if !keepCameraOn {
            await glasses.stopStreaming()
        }
        if let image, status == .live, let client {
            responseInFlight = true
            client.sendImage(image, note: prompt)
            client.createResponse()
        }
    }

    /// Speaks a line proactively (e.g. a late Antigravity coding job report), waiting out any
    /// response that is currently streaming, with an AVSpeechSynthesizer fallback if offline.
    func announce(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        print("[SuperMeta] Announcing job completion: \(trimmed)")
        fflush(stdout)
        if !transcript.hasSuffix("\n") && !transcript.isEmpty {
            transcript += "\n"
        }
        transcript += "[Antigravity]: \(trimmed)\n"

        guard status == .live, client != nil else {
            speakFallback(trimmed)
            return
        }
        if responseInFlight {
            announcementQueue.append(trimmed)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                guard let self, !self.announcementQueue.isEmpty else { return }
                self.responseInFlight = false
                self.drainQueuedWork()
            }
        } else {
            dispatchLiveAnnouncement(trimmed)
        }
    }

    private func dispatchLiveAnnouncement(_ text: String) {
        guard status == .live, let client else {
            speakFallback(text)
            return
        }
        let baselineChunks = receivedAudioChunks
        responseInFlight = true
        let prompt = "[Antigravity coding job finished — read a short spoken summary aloud to the wearer now]: \(text)"
        print("[SuperMeta] Dispatching live spoken report to Gemini Live")
        fflush(stdout)
        client.sendText(prompt)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard let self else { return }
            if self.receivedAudioChunks == baselineChunks {
                self.responseInFlight = false
                self.speakFallback(text)
            }
        }
    }

    private func speakFallback(_ text: String) {
        print("[SuperMeta] Speaking report via AVSpeechSynthesizer fallback: \(text)")
        fflush(stdout)
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }

    private func handle(_ event: RealtimeEvent) {
        switch event {
        case .sessionCreated, .sessionUpdated:
            status = .live
            print("[SuperMeta] Gemini Live session is LIVE")
            fflush(stdout)
            if ProcessInfo.processInfo.environment["SUPERMETA_AUTOTEST_VOICE"] == "1", !didRunAutotestClip {
                didRunAutotestClip = true
                Task { @MainActor [weak self] in
                    await self?.runAutotestVoiceStream()
                }
            }
        case let .assistantAudioDelta(data):
            receivedAudioChunks &+= 1
            responseInFlight = true
            audio.enqueue(pcm16: data)
        case let .assistantTextDelta(delta):
            transcript += delta
        case let .userTranscript(text):
            userLine = text
            print("[SuperMeta] User transcript chunk: \(text)")
            fflush(stdout)
        case .responseCreated:
            responseInFlight = true
        case .responseDone:
            if !transcript.hasSuffix("\n") { transcript += "\n" }
            print("[SuperMeta] Turn complete (audioChunks=\(receivedAudioChunks)): \(transcript.trimmingCharacters(in: .whitespacesAndNewlines))")
            fflush(stdout)
            responseInFlight = false
            drainQueuedWork()
        case let .functionCall(name, callID, argumentsJSON):
            print("[SuperMeta] Function call from Gemini: \(name) id=\(callID) args=\(argumentsJSON)")
            fflush(stdout)
            runTool(name: name, callID: callID, argumentsJSON: argumentsJSON)
        case let .error(message):
            print("[SuperMeta] Session error: \(message)")
            fflush(stdout)
            endWithError(message)
        case .other:
            break
        }
    }

    private func runAutotestVoiceStream() async {
        guard let client, let apiKey = providers?.realtimeAPIKey() else { return }
        suppressMicCapture = true
        defer { suppressMicCapture = false }
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let url = URL(string: "http://100.64.0.4:8796/api/supermeta/test-audio") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (pcmData, _) = try await URLSession.shared.data(for: req)
            print("[SuperMeta] Autotest: streaming \(pcmData.count) bytes of 16kHz spoken PCM to Gemini Live")
            fflush(stdout)
            let padded = pcmData + Data(count: 64_000)
            let chunkSize = 6_400
            var offset = 0
            while offset < padded.count {
                let end = min(offset + chunkSize, padded.count)
                client.appendAudio(padded.subdata(in: offset..<end))
                offset = end
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            print("[SuperMeta] Autotest: finished streaming spoken PCM request")
            fflush(stdout)
        } catch {
            print("[SuperMeta] Autotest audio fetch failed: \(error.localizedDescription)")
            fflush(stdout)
        }
    }

    private func runTool(name: String, callID: String, argumentsJSON: String) {
        Task { @MainActor [weak self] in
            guard let self, let client = self.client else { return }
            if GlassesTools.all.contains(where: { $0.name == name }) {
                let (output, pendingImage) = await self.handleGlassesTool(name: name, argumentsJSON: argumentsJSON)
                print("[SuperMeta] Tool result (\(name)): \(output)")
                fflush(stdout)
                self.responseInFlight = true
                client.sendFunctionOutput(callID: callID, output: output)
                if let pendingImage {
                    client.sendImage(pendingImage.jpeg, note: pendingImage.note)
                }
            } else {
                let output = await self.toolHandler?(name, argumentsJSON)
                    ?? #"{"error":"No agent is configured for tools"}"#
                print("[SuperMeta] Tool result (\(name)): \(output)")
                fflush(stdout)
                self.responseInFlight = true
                client.sendFunctionOutput(callID: callID, output: output)
            }
            if self.responseInFlight {
                self.pendingResponseCreate = true
            } else {
                client.createResponse()
            }
        }
    }

    private func handleGlassesTool(
        name: String,
        argumentsJSON: String
    ) async -> (output: String, pendingImage: (jpeg: Data, note: String)?) {
        if name == "glasses_end_session" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self?.stop()
            }
            return (#"{"status":"ending session now"}"#, nil)
        }
        guard let glasses else { return (#"{"error":"Glasses are unavailable"}"#, nil) }
        switch name {
        case "glasses_start_camera":
            cameraStartedByUser = true
            await glasses.startStreaming()
            let started = await glasses.waitForStreaming(timeout: 5.0)
            if started || glasses.streamState == .waiting {
                startFrameInjection()
                if let firstFrame = await glasses.waitForFreshFrame(maxWidth: 1280, quality: 0.75, timeout: 2.5) {
                    return (#"{"status":"glasses camera turned on and streaming live"}"#, (jpeg: firstFrame, note: "The wearer asked to turn on the glasses camera. It is now on and streaming live. Confirm briefly that the camera is on."))
                }
                return (#"{"status":"glasses camera turned on and streaming live"}"#, nil)
            }
            cameraStartedByUser = false
            return (#"{"error":"Camera did not start. Make sure the glasses are connected and camera permission is granted."}"#, nil)
        case "glasses_stop_camera":
            cameraStartedByUser = false
            frameTask?.cancel()
            frameTask = nil
            await glasses.stopStreaming()
            return (#"{"status":"glasses camera turned off"}"#, nil)
        case "glasses_look", "glasses_take_photo":
            let keepCameraOn = glasses.isStreaming || cameraStartedByUser
            var image: Data?
            if glasses.isStreaming, let current = glasses.currentFrameJPEG(maxWidth: 1280, quality: 0.75) {
                image = current
            } else {
                await glasses.startStreaming()
                _ = await glasses.waitForStreaming(timeout: 4.5)
                image = await glasses.waitForFreshFrame(maxWidth: 1280, quality: 0.75, timeout: 4.0)
                if image == nil {
                    image = try? await glasses.capturePhoto(timeout: 4.0)
                }
            }
            if !keepCameraOn {
                await glasses.stopStreaming()
            }
            guard let image else {
                return (#"{"error":"No glasses image is available. Make sure the glasses are connected and camera permission is granted."}"#, nil)
            }
            let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any]
            let note = args?["question"] as? String ?? (name == "glasses_look" ? "Describe exactly what is visible in this fresh glasses image." : "The wearer requested this photo. Confirm it was captured and describe it if useful.")
            return (#"{"status":"fresh glasses image sent to Gemini"}"#, (jpeg: image, note: note))
        default:
            return (#"{"error":"Unknown glasses tool"}"#, nil)
        }
    }

    private func drainQueuedWork() {
        guard let client else { return }
        if pendingResponseCreate {
            pendingResponseCreate = false
            client.createResponse()
        } else if !announcementQueue.isEmpty {
            let next = announcementQueue.removeFirst()
            dispatchLiveAnnouncement(next)
        }
    }

    /// A failed connection must release the microphone for the wake listener.
    /// Otherwise an invalid Live setup leaves "Hey Gemini" permanently paused.
    private func endWithError(_ message: String) {
        frameTask?.cancel(); frameTask = nil
        eventTask?.cancel(); eventTask = nil
        deactivateRemoteControlForSession()
        if cameraStartedByUser, let glasses {
            cameraStartedByUser = false
            Task { await glasses.stopStreaming() }
        }
        audio.stop()
        client?.disconnect()
        client = nil
        status = .error(message)
        WakeWordListener.shared.resume()
    }

    private func startFrameInjection() {
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, self.status == .live, self.cameraStartedByUser, let glasses = self.glasses else { continue }
                if !glasses.isStreaming { await glasses.startStreaming() }
                if let jpeg = glasses.currentFrameJPEG(maxWidth: 1024, quality: 0.7) {
                    self.client?.sendImage(jpeg, note: "")
                }
            }
        }
    }
}
