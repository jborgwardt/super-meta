#if os(iOS)
import Foundation
import AVFoundation
import os.log

private let log = Logger(subsystem: "com.priyanshu.metamod", category: "RealtimeAudio")

/// Unified, lock-screen-safe audio engine shared by `WakeWordListener` and `RealtimeSession`.
/// Keeping a single `AVAudioEngine` running continuously across wake-word standby and
/// Gemini Live sessions prevents iOS (`mediaserverd`) from revoking background audio
/// privileges with `OSStatus 560557684` (`AVAudioSessionErrorCodeCannotInterruptOthers`)
/// when transitioning while the iPhone is locked.
public final class RealtimeAudioEngine: @unchecked Sendable {
    public static let shared = RealtimeAudioEngine()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let stateLock = NSLock()

    /// Mic PCM16 wire format. Sample rate is chosen per provider in `start`
    /// (24 kHz for OpenAI, 16 kHz for Gemini Live).
    private var wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    /// Float32 @ 24 kHz for the player node (both providers emit 24 kHz audio).
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    private var onMicChunk: (@Sendable (Data) -> Void)?
    private var onWakeBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var keepRunningForWake = false
    private var tapInstalled = false
    private var tapInputFormat: AVAudioFormat?
    private var captureConverter: AVAudioConverter?
    private var playerAttached = false
    private let playbackLock = NSLock()
    private var playbackCursor: Date = .distantPast

    public init() {}

    // MARK: - Live AI Capture & Playback

    public func start(captureSampleRate: Double = 16_000, onMicChunk: @escaping @Sendable (Data) -> Void) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: captureSampleRate, channels: 1, interleaved: true)!
        if let tapInputFormat {
            captureConverter = AVAudioConverter(from: tapInputFormat, to: wireFormat)
        }
        self.onMicChunk = onMicChunk

        try ensureEngineRunningLocked()
        if !player.isPlaying {
            player.play()
        }
    }

    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }

        self.onMicChunk = nil
        playbackLock.lock()
        playbackCursor = .distantPast
        playbackLock.unlock()

        player.stop()
        if keepRunningForWake && engine.isRunning {
            // Keep engine & AVAudioSession alive so locked-screen wake listening never drops.
            player.play()
            return
        }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Wake Word Tap Sharing

    public func startWakeTap(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        keepRunningForWake = true
        onWakeBuffer = onBuffer
        try ensureEngineRunningLocked()
    }

    public func pauseWakeTap() {
        stateLock.lock()
        onWakeBuffer = nil
        stateLock.unlock()
    }

    public func stopWakeTap(deactivate: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }

        onWakeBuffer = nil
        keepRunningForWake = false
        guard onMicChunk == nil else { return }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        if deactivate {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    public func handleRouteChange() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard keepRunningForWake || onMicChunk != nil else { return }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        try? ensureEngineRunningLocked()
    }

    // MARK: - Core Engine Setup

    private func ensureEngineRunningLocked() throws {
        if engine.isRunning && tapInstalled {
            return
        }

        let session = AVAudioSession.sharedInstance()
        // Only configure category/active if needed; ignore redundant errors when
        // transitioning in the background while locked.
        try? session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try? session.setActive(true, options: [])

        let glassesTypes: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE, .headsetMic]
        if let glasses = session.availableInputs?.first(where: { input in
            glassesTypes.contains(input.portType)
                && ["meta", "ray-ban", "rayban"].contains { input.portName.lowercased().contains($0) }
        }) ?? session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? session.setPreferredInput(glasses)
        }

        if !playerAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playFormat)
            playerAttached = true
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "RealtimeAudioEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone input is unavailable"])
        }
        tapInputFormat = inputFormat
        captureConverter = AVAudioConverter(from: inputFormat, to: wireFormat)

        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInputTap(buffer)
        }
        tapInstalled = true

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    // MARK: - Playback & Synthesized Cues

    /// Plays a short, non-interrupting two-tone cue directly on the running `AVAudioPlayerNode`
    /// so locked-screen transitions never invoke `AudioServicesPlaySystemSound`.
    public func playCue(rising: Bool) {
        let sampleRate = playFormat.sampleRate
        let totalFrames = AVAudioFrameCount(sampleRate * 0.14)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: totalFrames),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = totalFrames
        let f1: Double = rising ? 587.33 : 659.25 // D5 / E5
        let f2: Double = rising ? 880.00 : 523.25 // A5 / C5
        let half = Int(totalFrames) / 2
        for i in 0..<Int(totalFrames) {
            let freq = i < half ? f1 : f2
            let env = Float(sin(Double.pi * Double(i % half) / Double(half)))
            channel[i] = Float(sin(2.0 * Double.pi * freq * Double(i) / sampleRate)) * 0.12 * env
        }
        stateLock.lock()
        let isRunning = engine.isRunning && playerAttached
        stateLock.unlock()
        guard isRunning else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// Enqueue a PCM16 @ 24 kHz audio delta from the model for playback.
    public func enqueue(pcm16 data: Data) {
        guard let buffer = Self.pcm16ToFloatBuffer(data, format: playFormat) else { return }
        let duration = Double(buffer.frameLength) / playFormat.sampleRate
        playbackLock.lock()
        let base = max(Date(), playbackCursor)
        playbackCursor = base.addingTimeInterval(duration)
        playbackLock.unlock()
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    // MARK: - Tap Routing

    private func handleInputTap(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let micCallback = onMicChunk
        let wakeCallback = onWakeBuffer
        let converter = captureConverter
        let targetFormat = wireFormat
        stateLock.unlock()

        if let micCallback, let converter {
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { return }
            var error: NSError?
            var fed = false
            let status = converter.convert(to: out, error: &error) { _, inStatus in
                if fed { inStatus.pointee = .noDataNow; return nil }
                fed = true
                inStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, out.frameLength > 0,
                  let channelData = out.int16ChannelData else { return }
            let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
            playbackLock.lock()
            let isPlayingAssistantAudio = Date() < playbackCursor.addingTimeInterval(0.45)
            playbackLock.unlock()
            if isPlayingAssistantAudio {
                micCallback(Data(count: byteCount))
                return
            }
            let data = Data(bytes: channelData[0], count: byteCount)
            micCallback(data)
        } else if let wakeCallback {
            wakeCallback(buffer)
        }
    }

    static func pcm16ToFloatBuffer(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
              let floatChannel = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                floatChannel[0][i] = Float(samples[i]) / Float(Int16.max)
            }
        }
        return buffer
    }
}
#endif
