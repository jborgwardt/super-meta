import Foundation
import SwiftUI
@preconcurrency import Speech
import AVFoundation
import RealtimeVoice

/// Drives on-device `SFSpeechRecognizer` over the shared `RealtimeAudioEngine.shared`
/// tap so wake-word detection and Gemini Live share a single, continuously running
/// `AVAudioEngine`. This prevents iOS (`mediaserverd`) from failing with
/// `OSStatus 560557684` (`!int`) when waking while the iPhone is locked.
private final class WakeAudioEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.priyanshu.metamod.wakeword.audio")
    private lazy var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognitionGeneration = 0

    /// Partial transcript text; fires on the recognition thread.
    var onPartial: (@Sendable (String) -> Void)?
    /// Recognizer finalized or errored, or setup failed → owner should restart.
    var onEnd: (@Sendable () -> Void)?

    /// (Re)start recognition. Non-blocking: all work happens on the serial queue.
    func start(contextualStrings: [String]) {
        queue.async { [weak self] in self?._start(contextualStrings) }
    }

    /// Pause recognition for Gemini Live while keeping the shared `AVAudioEngine` running.
    func pause(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            self?._pause()
            completion?()
        }
    }

    /// Tear down recognition; optionally deactivate the shared audio session.
    func stop(deactivate: Bool = false, completion: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            self?._stop(deactivate: deactivate)
            completion?()
        }
    }

    func handleRouteChange() {
        queue.async {
            RealtimeAudioEngine.shared.handleRouteChange()
        }
    }

    private func _start(_ contextual: [String]) {
        recognitionGeneration &+= 1
        let generation = recognitionGeneration
        _pause(invalidateRecognition: false)
        guard let recognizer, recognizer.isAvailable else { onEnd?(); return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .search
        req.contextualStrings = contextual
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request = req

        do {
            try RealtimeAudioEngine.shared.startWakeTap { [weak req] buffer in
                req?.append(buffer)
            }
        } catch {
            onEnd?()
            return
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard self?.recognitionGeneration == generation else { return }
            if let result { self?.onPartial?(result.bestTranscription.formattedString) }
            if error != nil || (result?.isFinal ?? false) { self?.onEnd?() }
        }
    }

    private func _pause(invalidateRecognition: Bool = true) {
        if invalidateRecognition { recognitionGeneration &+= 1 }
        RealtimeAudioEngine.shared.pauseWakeTap()
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
    }

    private func _stop(deactivate: Bool, invalidateRecognition: Bool = true) {
        if invalidateRecognition { recognitionGeneration &+= 1 }
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        RealtimeAudioEngine.shared.stopWakeTap(deactivate: deactivate)
    }
}

/// Always-on wake-phrase listener. Runs an on-device `SFSpeechRecognizer` over a
/// dedicated `AVAudioEngine` tap so a user-chosen phrase ("hey neo", "hey vision"…)
/// can start Live AI hands-free — heard through the glasses' Bluetooth HFP mic when
/// they're connected, otherwise the phone mic, and while the app is backgrounded /
/// the phone is locked (the active audio session keeps the app alive).
///
/// This object stays on the main actor for its published state and restart timing;
/// the actual audio work lives in `WakeAudioEngine` on a background queue so enabling
/// the toggle never freezes the UI. Restart throttling, route/interruption observers,
/// and recognizer-restart handling keep recognition alive across the flaky HFP link.
@MainActor
final class WakeWordListener: ObservableObject {
    static let shared = WakeWordListener()

    /// Master switch. Persisted; enabling starts listening, disabling tears down.
    @Published var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            defaults.set(enabled, forKey: Keys.enabled)
            if enabled { start() } else { stop() }
        }
    }

    /// The phrase to listen for. Matched case-insensitively as a substring of
    /// partial transcripts; empty is ignored (kept as the last non-empty value).
    @Published var phrase: String {
        didSet {
            let trimmed = phrase.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            defaults.set(trimmed, forKey: Keys.phrase)
            // Rebias the recognizer for the new phrase.
            if listening { scheduleRestart() }
        }
    }

    /// Invoked on the main actor when the wake phrase is detected. Set by the app.
    var onWake: (() -> Void)?

    private let audio = WakeAudioEngine()

    /// True while the user wants us listening (toggle on and not paused).
    private var listening = false
    /// True while a realtime session is holding the mic; we suspend then.
    private var paused = false
    /// Guards against restart storms — recognizers can die and re-fire instantly.
    private var lastRestart = Date.distantPast
    /// Cooldown so one utterance doesn't fire the wake handler repeatedly.
    private var lastWake = Date.distantPast
    private var restartScheduled = false
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let enabled = "always_on_phone_mic_wake_enabled"
        static let phrase = "wake_phrase"
    }

    private init() {
        // Off by default so the iPhone orange mic indicator stays off while idle,
        // the mic stays with iOS and other apps when no conversation is active, and
        // the glasses stay out of Bluetooth HFP call mode so "Hey Meta, start Gem" works.
        self.enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        self.phrase = defaults.string(forKey: Keys.phrase) ?? "hey gemini"

        audio.onPartial = { [weak self] text in
            Task { @MainActor in self?.evaluate(text) }
        }
        audio.onEnd = { [weak self] in
            Task { @MainActor in
                guard let self, self.listening, !self.paused else { return }
                self.scheduleRestart()
            }
        }

        // AVAudioSession posts these on a background thread. Deliver on the main
        // queue so the main-actor closure body runs on the main actor — otherwise
        // Swift's isolation check (swift_task_isCurrentExecutor) traps and kills the
        // app when a Bluetooth route change fires on a real device.
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self, self.listening, !self.paused else { return }
                // Category changes and .override (posted by our own setPreferredInput)
                // must be ignored; only recover real physical device connect/disconnect.
                guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
                self.audio.handleRouteChange()
                self.scheduleRestart(after: 0.5)
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self, self.listening, !self.paused else { return }
                switch type {
                case .began: self.audio.pause()
                case .ended:
                    self.audio.handleRouteChange()
                    self.scheduleRestart()
                default: break
                }
            }
        }
    }

    // MARK: Lifecycle

    /// Begin listening if enabled. Requests microphone AND speech permission first
    /// (both up front, like OpenGlasses) so starting the audio engine never stalls
    /// waiting on a permission prompt.
    func start() {
        guard enabled, !listening else { return }
        Task { @MainActor in
            let mic = await AVAudioApplication.requestRecordPermission()
            let speech = await Self.requestSpeechAuthorization()
            guard self.enabled else { return }
            guard mic, speech else {
                // Permission denied — revert the toggle so Settings reflects reality.
                self.enabled = false
                return
            }
            self.listening = true
            self.paused = false
            self.beginRecognition()
        }
    }

    // `nonisolated`: SFSpeechRecognizer.requestAuthorization invokes its handler on a
    // background queue. If this stayed main-actor-isolated (the default for a static
    // member of a @MainActor type), Swift 6's runtime executor check would trap when
    // TCC calls the closure off-main. nonisolated lets the continuation resume from
    // any thread; the awaiting @MainActor caller still resumes on the main actor.
    nonisolated private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    /// Stop listening entirely (toggle off).
    func stop() {
        guard listening || paused else { return }
        listening = false
        paused = false
        audio.stop(deactivate: true)
    }

    /// Release the mic for a realtime session without forgetting we want to listen.
    func pause() { pause(then: nil) }

    /// Pauses speech recognition while keeping the shared `AVAudioEngine` running
    /// so Gemini Live can immediately take over mic capture even when the phone is locked.
    func pause(then completion: (@Sendable () -> Void)?) {
        guard listening, !paused else {
            completion?()
            return
        }
        paused = true
        audio.pause {
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Resume listening after a realtime session ends.
    func resume() {
        guard listening, paused else { return }
        paused = false
        Self.playListeningEndedCue()
        scheduleRestart()
    }

    // MARK: Recognition

    private func beginRecognition() {
        guard listening, !paused else { return }
        // Non-blocking: the audio engine does its work on its own queue.
        audio.start(contextualStrings: contextualStrings())
    }

    /// Throttled restart. The audio engine revives in place (rather than rebuilding),
    /// which is what survives glasses connect/disconnect.
    private func scheduleRestart(after requestedDelay: TimeInterval? = nil) {
        guard listening, !paused, !restartScheduled else { return }
        restartScheduled = true
        let elapsed = Date().timeIntervalSince(lastRestart)
        let delay = max(requestedDelay ?? 0, 0.6 - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.restartScheduled = false
            guard self.listening, !self.paused else { return }
            self.lastRestart = Date()
            self.beginRecognition()
        }
    }

    private func evaluate(_ transcript: String) {
        let needle = Self.normalizedWords(phrase)
        guard !needle.isEmpty else { return }
        // Speech frequently transcribes a wake phrase as "Hey, Gemini". Compare
        // word-normalized text so punctuation, case, and extra whitespace do not
        // prevent an otherwise exact wake phrase from firing.
        guard Self.matchesWakePhrase(transcript, phrase: needle) else { return }
        // Cooldown so one long partial doesn't re-fire.
        guard Date().timeIntervalSince(lastWake) > 2 else { return }
        lastWake = Date()
        Self.playListeningStartedCue()
        onWake?()
    }

    /// Plays non-interrupting cues directly through the running `RealtimeAudioEngine.shared`
    /// player node so `SystemSoundServer` never interrupts the session while locked.
    nonisolated private static func playListeningStartedCue() {
        RealtimeAudioEngine.shared.playCue(rising: true)
    }

    nonisolated private static func playListeningEndedCue() {
        RealtimeAudioEngine.shared.playCue(rising: false)
    }

    private static func normalizedWords(_ text: String) -> String {
        let scalars = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
        return scalars.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func matchesWakePhrase(_ transcript: String, phrase: String) -> Bool {
        let normalized = normalizedWords(transcript)
        var candidates = [phrase]
        if phrase == "hey gemini" || phrase == "hey antigravity" {
            candidates += ["hey gemini", "okay gemini", "ok gemini", "hey geminy", "hey jiminy", "hey antigravity", "ok antigravity", "hey anti gravity"]
        }
        return candidates.contains { normalized.contains($0) }
    }

    /// The phrase plus a few spacing/homophone variants — biasing is the single
    /// biggest reliability lever over the glasses' low-bitrate HFP mic.
    private func contextualStrings() -> [String] {
        let base = phrase.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return [] }
        var out: Set<String> = [base, base.lowercased(), "Hey Gemini", "Hey Antigravity", "Antigravity"]
        let words = base.split(separator: " ")
        if words.count >= 2 {
            out.insert(words.joined(separator: ", "))
            if let last = words.last { out.insert(String(last)) }
        }
        return Array(out)
    }
}
