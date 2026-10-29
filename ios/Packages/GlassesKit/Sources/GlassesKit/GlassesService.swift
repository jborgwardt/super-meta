import Foundation
import UIKit
import MWDATCore
import MWDATCamera
import MWDATSpeech
import os.log

private let log = Logger(subsystem: "com.priyanshu.metamod", category: "GlassesKit")

/// High-level connection state for the glasses, decoupled from the SDK's enums.
public enum GlassesRegistration: Sendable, Equatable {
    case unknown
    case notRegistered
    case registering
    case registered
}

/// High-level streaming state.
public enum GlassesStreamState: Sendable, Equatable {
    case stopped
    case waiting
    case streaming
    case error(String)
}

/// Desired video resolution.
public enum GlassesVideoQuality: String, Sendable, CaseIterable {
    case low, medium, high

    var sdkResolution: StreamingResolution {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}

/// A clean async/observable wrapper over the Meta Wearables DAT SDK.
///
/// Owns a single `StreamSession` (the SDK requires one reused instance) and
/// republishes device, stream, frame, and photo events. Features depend on this,
/// never on the SDK directly.
///
/// Connection persistence: registration with the Meta AI app is persisted by the
/// SDK across launches, so we only ever *observe* `registrationState` and call
/// `startRegistration()` on an explicit user tap — the user pairs once, not every
/// launch. The glasses stay owned by the Meta AI app (a DAT third-party app is a
/// secondary session consumer, not an exclusive owner); what we can guarantee is
/// that Super Meta re-acquires its session automatically. When the device drops —
/// backgrounding, or the Meta app taking over — the session goes `waitingForDevice`;
/// when it returns (or we re-enter the foreground) we resume without user action,
/// so there's no manual "reconnect" step during a session.
///
/// If the SDK cannot be configured (e.g. running in the Simulator with no Meta
/// credentials, where there are no glasses anyway), the service degrades to an
/// `unavailable` state instead of crashing — `isAvailable == false`.
@MainActor
public final class GlassesService: ObservableObject {

    // MARK: Published state
    @Published public private(set) var isAvailable = false
    @Published public private(set) var registration: GlassesRegistration = .unknown
    @Published public private(set) var hasActiveDevice = false
    @Published public private(set) var streamState: GlassesStreamState = .stopped
    @Published public private(set) var latestFrame: UIImage?
    @Published public private(set) var lastError: String?

    public var isStreaming: Bool { streamState == .streaming }

    /// Invoked on the main actor when Meta AI triggers a voice invocation (`"Hey Meta, start Gem"`).
    public var onVoiceInvocation: (@MainActor () -> Void)?

    // MARK: SDK handles (nil when the SDK isn't configured)
    private var wearables: WearablesInterface?
    private var deviceSession: DeviceSession?
    private var camera: MWDATCamera.Camera?
    private var speech: MWDATSpeech.Speech?
    private var speechHasStarted = false
    private var wantsConversationSpeech = false
    private var speechRevivalTask: Task<Void, Never>?
    private var streamConfig = StreamConfiguration(
        videoCodec: VideoCodec.raw,
        resolution: .medium,
        frameRate: 24
    )

    private var sessionStateToken: AnyListenerToken?
    private var sessionErrorToken: AnyListenerToken?
    private var stateToken: AnyListenerToken?
    private var frameToken: AnyListenerToken?
    private var errorToken: AnyListenerToken?
    private var photoToken: AnyListenerToken?
    private var speechTranscriptToken: AnyListenerToken?
    private var speechStateToken: AnyListenerToken?
    private var speechErrorToken: AnyListenerToken?
    private var voiceStream: VoiceInvocationsStream?
    private var voiceListeningOn: DeviceIdentifier?
    private var voiceDropSignal: AsyncStream<Void>.Continuation?
    private var voiceClosedOnPurpose = false
    private var voiceReopenHold: AsyncStream<Void>?
    private var voiceInvocationToken: AnyListenerToken?
    private var voiceErrorToken: AnyListenerToken?
    private var voiceTask: Task<Void, Never>?
    private var voiceForegroundTick: Int = 0
    private var deviceTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var isProcessingFrame = false
    private var frameSequence: UInt64 = 0
    private var photoContinuation: CheckedContinuation<Data, Error>?

    private static let voiceReopenFloorNanos: UInt64 = 500_000_000
    private static let voiceReopenCeilingNanos: UInt64 = 30_000_000_000

    /// True while the user intends to be streaming. Drives automatic resume when the
    /// device reappears or the app returns to the foreground, so no manual reconnect
    /// is needed. Cleared only by an explicit `stopStreaming()`.
    private var wantsStreaming = false
    // Set once on the main actor, read only in the nonisolated deinit for removal.
    nonisolated(unsafe) private var foregroundToken: NSObjectProtocol?

    private static var didConfigure = false

    /// Attempts to configure the DAT SDK exactly once. Returns whether the SDK is usable.
    @discardableResult
    public static func configureSDK() -> Bool {
        if didConfigure { return true }
        do {
            try Wearables.configure()
            didConfigure = true
            log.info("Wearables SDK configured")
            return true
        } catch {
            log.error("Wearables.configure() failed (glasses unavailable): \(String(describing: error))")
            return false
        }
    }

    public init(quality: GlassesVideoQuality = .medium) {
        guard Self.configureSDK() else {
            isAvailable = false
            registration = .notRegistered
            lastError = "Glasses SDK unavailable — set your Meta credentials and run on a device."
            return
        }

        let wearables = Wearables.shared
        self.streamConfig = StreamConfiguration(
            videoCodec: VideoCodec.raw,
            resolution: quality.sdkResolution,
            frameRate: 24
        )

        self.wearables = wearables
        self.isAvailable = true
        self.streamState = .stopped

        observeRegistration(wearables)
        observeDevices(wearables)
        observeAppLifecycle()
        startVoiceInvocationMonitor(wearables)
    }

    // MARK: - Registration

    /// Registers the app with the Meta AI app. No-op when already registered or
    /// mid-flight — registration persists across launches, so this should only ever
    /// run once per install (on an explicit user tap), never on every launch.
    public func startRegistration() async {
        guard let wearables else {
            setError("Glasses SDK is unavailable")
            return
        }
        guard registration != .registering, registration != .registered else {
            log.info("Ignoring registration request; state is already \(String(describing: self.registration))")
            return
        }
        log.info("Starting Meta AI DAT registration handoff")
        do {
            try await wearables.startRegistration()
            log.info("Meta AI DAT registration handoff started")
        } catch {
            // If DCAppAttest state in Keychain is stale across reinstalls, reset hasLaunched once and retry.
            UserDefaults.standard.set(false, forKey: "com.meta.wearable.dat.attestation.hasLaunched")
            do {
                try await wearables.startRegistration()
                log.info("Meta AI DAT registration handoff started after attestation reset")
            } catch {
                log.error("Meta AI DAT registration failed: \(String(describing: error))")
                setError("Registration failed: \(error.localizedDescription)")
            }
        }
    }

    /// Unlinks the app from the glasses (the connect toggle turned off).
    public func startUnregistration() async {
        guard let wearables else { return }
        do { try await wearables.startUnregistration() }
        catch { setError("Couldn't disconnect: \(error.localizedDescription)") }
    }

    /// Completes registration / permission flows and voice-launch deep links.
    /// Matches `BirdSpotterApp.swift`: passes all incoming app-scheme URLs directly to
    /// `Wearables.shared.handleUrl(url)` without filtering on query items.
    public func handleCallbackURL(_ url: URL) {
        guard let wearables else { return }
        Self.appendDebugLog("opened by URL — \(url.absoluteString)")
        Task { @MainActor in
            do {
                let handled = try await wearables.handleUrl(url)
                Self.appendDebugLog("Wearables.handleUrl handled=\(handled)")
            } catch {
                log.error("Meta AI DAT callback failed: \(String(describing: error))")
                Self.appendDebugLog("Wearables.handleUrl error=\(String(reflecting: error))")
                setError("Couldn't finish connecting: \(error.localizedDescription)")
            }
        }
    }

    private func observeRegistration(_ wearables: WearablesInterface) {
        registration = map(wearables.registrationState)
        syncDeviceMonitoring()
        registrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in wearables.registrationStateStream() {
                self.registration = self.map(state)
                Self.appendDebugLog("registrationState=\(String(describing: state))")
                self.syncDeviceMonitoring()
            }
        }
    }

    private func syncDeviceMonitoring() {
        // Connection status comes from activeDeviceStream (observeDevice).
    }

    private func map(_ state: RegistrationState) -> GlassesRegistration {
        if state == .registered { return .registered }
        if state == .registering { return .registering }
        return .notRegistered
    }

    // MARK: - Device & Voice Invocations ("Hey Meta, start/open Code")

    nonisolated private static func appendDebugLog(_ message: String) {
        NSLog("[Glasses] %@", message)
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let fileURL = caches.appendingPathComponent("glasses_debug.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [Glasses] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private static func rank(_ device: Device) -> Int {
        if device.linkState == .connected && device.donState == .donned { return 0 }
        if device.linkState == .connected { return 1 }
        if device.compatibility() == .compatible { return 2 }
        return 3
    }

    private func preferredDeviceIdentifier() -> DeviceIdentifier? {
        guard let wearables else { return nil }
        let devices = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        return devices.min { Self.rank($0) < Self.rank($1) }?.identifier ?? wearables.devices.first
    }

    private func preferredConnectedDeviceIdentifier() -> DeviceIdentifier? {
        guard let wearables else { return nil }
        let connected = wearables.devices
            .compactMap { wearables.deviceForIdentifier($0) }
            .filter { $0.linkState == .connected && $0.compatibility() == .compatible }
        return connected.min { Self.rank($0) < Self.rank($1) }?.identifier
    }

    private func hasAnyConnectedDevice() -> Bool {
        guard let wearables else { return false }
        return wearables.devices
            .compactMap { wearables.deviceForIdentifier($0) }
            .contains { $0.linkState == .connected }
    }

    /// Hey Meta voice channel, matching `BirdSpotter`'s `DatGlassesVoiceRepository` 1:1.
    ///
    /// Waits for registration, immediately opens `VoiceInvocationsStream(wearables:)`
    /// (with no sleep ahead of creation so a launch held open by Meta AI is caught
    /// immediately), follows `devicesStream()` + per-device link/compatibility listeners
    /// via `ensureVoiceListening()`, answers `LaunchApp` before any session work, and
    /// reopens with exponential backoff (`0.5s` doubling to `30s`) whenever `errorPublisher`
    /// signals a drop.
    private func startVoiceInvocationMonitor(_ wearables: WearablesInterface) {
        voiceTask?.cancel()
        voiceTask = Task { @MainActor [weak self] in
            var reopenDelay = Self.voiceReopenFloorNanos
            while !Task.isCancelled {
                guard let self else { return }
                await self.waitUntilVoiceRegistered()
                if Task.isCancelled { break }

                let (dropped, didListen) = await self.listenVoiceOnce()
                if !dropped || Task.isCancelled { break }

                if didListen {
                    reopenDelay = Self.voiceReopenFloorNanos
                }
                if self.voiceClosedOnPurpose {
                    self.voiceClosedOnPurpose = false
                    reopenDelay = Self.voiceReopenFloorNanos
                    if let hold = self.voiceReopenHold {
                        for await _ in hold { break }
                    }
                }

                let startTick = self.voiceForegroundTick
                var slept: UInt64 = 0
                let slice: UInt64 = 250_000_000
                while slept < reopenDelay && !Task.isCancelled {
                    if self.voiceForegroundTick != startTick {
                        reopenDelay = Self.voiceReopenFloorNanos
                        break
                    }
                    let step = min(slice, reopenDelay - slept)
                    try? await Task.sleep(nanoseconds: step)
                    slept &+= step
                }
                reopenDelay = min(reopenDelay * 2, Self.voiceReopenCeilingNanos)
            }
        }
    }

    private func waitUntilVoiceRegistered() async {
        guard let wearables else { return }
        if case .registered = wearables.registrationState { return }
        Self.appendDebugLog("voice channel waiting for registration")
        for await state in wearables.registrationStateStream() {
            if Task.isCancelled { return }
            if case .registered = state { return }
        }
    }

    /// Runs `body` with the voice channel closed (`DatGlassesVoiceRepository.withChannelClosed`).
    public func withVoiceChannelClosed(_ body: () async -> Void) async {
        guard let dropSignal = voiceDropSignal else {
            await body()
            return
        }
        let (hold, release) = AsyncStream<Void>.makeStream()
        voiceReopenHold = hold
        voiceClosedOnPurpose = true
        dropSignal.yield()
        for _ in 0..<20 where voiceStream != nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await body()
        release.finish()
        voiceReopenHold = nil
    }

    /// One lease of the voice channel (`DatGlassesVoiceRepository.listenOnce`).
    private func listenVoiceOnce() async -> (dropped: Bool, didListen: Bool) {
        guard let wearables else { return (false, false) }
        let stream: VoiceInvocationsStream
        do {
            stream = try VoiceInvocationsStream(wearables: wearables)
        } catch {
            Self.appendDebugLog("voice channel — would not open: \(String(describing: error))")
            return (true, false)
        }
        self.voiceStream = stream
        self.voiceListeningOn = nil
        Self.appendDebugLog("voice channel — open, waiting on Meta AI")

        let (drops, dropSignal) = AsyncStream<Void>.makeStream()
        self.voiceDropSignal = dropSignal

        voiceInvocationToken = stream.invocationsPublisher.listen { [weak self] invocation in
            Task { @MainActor [weak self] in
                await self?.answerVoiceInvocation(invocation)
            }
        }
        voiceErrorToken = stream.errorPublisher.listen { error in
            Self.appendDebugLog("voice channel — \(String(reflecting: error)): \(error.description)")
            dropSignal.yield()
        }

        let deviceMonitor = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let wearables = self.wearables else { return }
            var deviceTokens: [AnyListenerToken] = []
            for await identifiers in wearables.devicesStream() {
                if Task.isCancelled { break }
                for token in deviceTokens { await token.cancel() }
                deviceTokens.removeAll()

                self.ensureVoiceListening()

                let devices = identifiers.compactMap { wearables.deviceForIdentifier($0) }
                for device in devices {
                    deviceTokens.append(
                        device.addLinkStateListener { [weak self] _ in
                            guard let self else { return }
                            Task { @MainActor in self.ensureVoiceListening() }
                        }
                    )
                    deviceTokens.append(
                        device.addCompatibilityListener { [weak self] _ in
                            guard let self else { return }
                            Task { @MainActor in self.ensureVoiceListening() }
                        }
                    )
                }
            }
            for token in deviceTokens { await token.cancel() }
        }

        var dropped = false
        for await _ in drops {
            dropped = true
            break
        }
        deviceMonitor.cancel()

        let didListen = (voiceListeningOn != nil)
        if voiceListeningOn != nil {
            stream.stop()
        }
        self.voiceStream = nil
        self.voiceDropSignal = nil
        self.voiceListeningOn = nil
        if let token = voiceInvocationToken {
            await token.cancel()
            voiceInvocationToken = nil
        }
        if let token = voiceErrorToken {
            await token.cancel()
            voiceErrorToken = nil
        }
        return (dropped, didListen)
    }

    /// Starts the channel on the preferred pair, or moves it there (`DatGlassesVoiceRepository.ensureListening`).
    /// A failed start leaves `voiceListeningOn` empty on purpose so the next roster or link
    /// change asks again without tearing down the lease.
    private func ensureVoiceListening() {
        guard let stream = voiceStream else { return }
        guard let preferred = preferredDeviceIdentifier(),
              preferred != voiceListeningOn
        else { return }
        if voiceListeningOn != nil {
            stream.stop()
        }
        voiceListeningOn = nil
        do {
            try stream.start(deviceIdentifier: preferred)
            voiceListeningOn = preferred
            Self.appendDebugLog("voice channel — listening on \(preferred)")
        } catch {
            Self.appendDebugLog("voice channel — would not start on \(preferred): \(String(describing: error))")
        }
    }

    private func answerVoiceInvocation(_ invocation: any VoiceInvocation) async {
        switch invocation {
        case let launch as LaunchApp:
            Self.appendDebugLog("voice launch — answering Meta AI (device=\(launch.deviceIdentifier))")
            let delivered = await launch.responseHandle.sendSuccess(actionOutput: nil)
            if !delivered {
                Self.appendDebugLog("voice launch — the answer did not deliver")
            }
            onVoiceInvocation?()
        default:
            Self.appendDebugLog("voice — ignored \(String(describing: invocation))")
        }
    }

    private func observeDevices(_ wearables: WearablesInterface) {
        refreshActiveDeviceState()
        deviceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var deviceTokens: [AnyListenerToken] = []
            for await identifiers in wearables.devicesStream() {
                for token in deviceTokens { await token.cancel() }
                deviceTokens.removeAll()

                self.refreshActiveDeviceState()

                let devices = identifiers.compactMap { wearables.deviceForIdentifier($0) }
                for device in devices {
                    deviceTokens.append(
                        device.addLinkStateListener { [weak self] _ in
                            Task { @MainActor [weak self] in self?.refreshActiveDeviceState() }
                        }
                    )
                    deviceTokens.append(
                        device.addCompatibilityListener { [weak self] _ in
                            Task { @MainActor [weak self] in self?.refreshActiveDeviceState() }
                        }
                    )
                    deviceTokens.append(
                        device.addDeviceStateListener { [weak self] _ in
                            Task { @MainActor [weak self] in self?.refreshActiveDeviceState() }
                        }
                    )
                }
            }
            for token in deviceTokens { await token.cancel() }
        }
    }

    private func refreshActiveDeviceState() {
        let connected = hasAnyConnectedDevice()
        if hasActiveDevice != connected {
            Self.appendDebugLog("device roster connected=\(connected) preferred=\(String(describing: preferredDeviceIdentifier()))")
            hasActiveDevice = connected
        }
        if connected, wantsStreaming, !isStreaming {
            Task { @MainActor [weak self] in
                await self?.startStreaming()
            }
        }
    }

    /// Re-acquire the session when returning to the foreground. Never re-registers
    /// (registration is already persisted); only resumes an interrupted stream.
    private func observeAppLifecycle() {
        foregroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.voiceForegroundTick &+= 1
                if self.wantsStreaming, !self.isStreaming {
                    await self.startStreaming()
                }
            }
        }
    }

    // MARK: - On-Demand Session Helper (Shared by Camera & Conversation Speech Fallback)

    private func ensureDeviceSessionStarted() async throws -> DeviceSession {
        guard let wearables else { throw GlassesError.unavailable }
        let session: DeviceSession
        if let existing = deviceSession, existing.state != .stopped, existing.state != .stopping {
            session = existing
        } else {
            guard let preferred = preferredDeviceIdentifier() else {
                throw GlassesError.unavailable
            }
            session = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: preferred))
            deviceSession = session
            sessionStateToken = session.statePublisher.listen { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if state == .stopped {
                        self.camera = nil
                        self.speech = nil
                        self.speechHasStarted = false
                        self.deviceSession = nil
                        self.latestFrame = nil
                        self.streamState = .stopped
                    }
                }
            }
            sessionErrorToken = session.errorPublisher.listen { [weak self] error in
                Task { @MainActor [weak self] in
                    if case .dwaOutOfStuRange = error { return }
                    self?.setError(error.localizedDescription)
                }
            }
            try session.start()
        }

        var waited = 0
        while session.state != .started && waited < 200 {
            if session.state == .stopped { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        guard session.state == .started else {
            session.stop()
            deviceSession = nil
            throw GlassesError.unavailable
        }
        return session
    }

    // MARK: - Conversation Speech Fallback (Active Session Only, Never Idle)

    /// Starts on-glasses speech recognition (`MWDATSpeech`) strictly for the duration of an
    /// active Gemini Live conversation when iOS refuses `AVAudioEngine.inputNode` on a locked
    /// phone. Never touches the camera (`MWDATCamera` stays off).
    public func startConversationSpeech(
        onPartial: (@Sendable (String) -> Void)? = nil,
        onFinal: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        guard let wearables else { return false }
        wantsConversationSpeech = true
        do {
            let micStatus = try await wearables.checkPermissionStatus(Permission.microphone)
            if micStatus != .granted {
                guard UIApplication.shared.applicationState == .active else {
                    Self.appendDebugLog("MWDATSpeech microphone permission not granted and app is not active; cannot prompt on lock screen")
                    wantsConversationSpeech = false
                    return false
                }
                let requested = try await wearables.requestPermission(Permission.microphone)
                guard requested == .granted else {
                    Self.appendDebugLog("MWDATSpeech microphone permission not granted")
                    wantsConversationSpeech = false
                    return false
                }
            }
            let session = try await ensureDeviceSessionStarted()
            let activeSpeech: MWDATSpeech.Speech
            if let existing = speech {
                activeSpeech = existing
            } else {
                guard let created = try session.addSpeech() else {
                    Self.appendDebugLog("DeviceSession.addSpeech() returned nil")
                    wantsConversationSpeech = false
                    return false
                }
                speech = created
                activeSpeech = created
            }

            if let token = speechTranscriptToken { await token.cancel(); speechTranscriptToken = nil }
            if let token = speechStateToken { await token.cancel(); speechStateToken = nil }
            if let token = speechErrorToken { await token.cancel(); speechErrorToken = nil }

            speechHasStarted = false
            speechTranscriptToken = activeSpeech.transcriptionPublisher.listen { result in
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                if result.isFinal {
                    onFinal(text)
                } else {
                    onPartial?(text)
                }
            }
            speechStateToken = activeSpeech.statePublisher.listen { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .started:
                        self.speechHasStarted = true
                        Self.appendDebugLog("MWDATSpeech conversation recognizer started")
                    case .stopped:
                        guard self.speechHasStarted, self.wantsConversationSpeech else { break }
                        Self.appendDebugLog("MWDATSpeech conversation recognizer stopped; restarting in-place")
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if self.wantsConversationSpeech {
                            self.speech?.start()
                        }
                    default:
                        break
                    }
                }
            }
            speechErrorToken = activeSpeech.errorPublisher.listen { error in
                Self.appendDebugLog("MWDATSpeech error: \(String(reflecting: error))")
            }
            activeSpeech.start()

            // DeviceSession.state == .started arrives while the physical link may still be
            // exiting waitingForDevice (DatGlassesSessionRepository.swift:396-407). Retry
            // speech.start() with 750ms patience until speechHasStarted flips true.
            speechRevivalTask?.cancel()
            speechRevivalTask = Task { @MainActor [weak self] in
                for attempt in 1...8 {
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    guard let self, !Task.isCancelled, self.wantsConversationSpeech, !self.speechHasStarted else { return }
                    Self.appendDebugLog("MWDATSpeech patience retry #\(attempt)")
                    self.speech?.start()
                }
            }
            return true
        } catch {
            Self.appendDebugLog("startConversationSpeech failed: \(error.localizedDescription)")
            wantsConversationSpeech = false
            return false
        }
    }

    public func stopConversationSpeech() async {
        wantsConversationSpeech = false
        speechHasStarted = false
        speechRevivalTask?.cancel(); speechRevivalTask = nil
        if let token = speechTranscriptToken { await token.cancel(); speechTranscriptToken = nil }
        if let token = speechStateToken { await token.cancel(); speechStateToken = nil }
        if let token = speechErrorToken { await token.cancel(); speechErrorToken = nil }
        speech?.stop()
        speech = nil
        if !wantsStreaming {
            deviceSession?.stop()
            deviceSession = nil
        }
    }

    // MARK: - Streaming

    public func startStreaming() async {
        guard let wearables else { return }
        if let existingCamera = camera, existingCamera.stream.state == .streaming {
            return
        }
        // Mark intent up front so an interrupted stream auto-resumes even if the
        // device isn't ready yet (session parks in `waitingForDevice`).
        wantsStreaming = true
        lastError = nil
        streamState = .waiting
        do {
            let session = try await ensureDeviceSessionStarted()

            let status = try await wearables.checkPermissionStatus(Permission.camera)
            if status != .granted {
                let requested = try await wearables.requestPermission(Permission.camera)
                guard requested == .granted else {
                    setError("Camera permission denied")
                    streamState = .stopped
                    return
                }
            }

            let activeCamera: MWDATCamera.Camera
            if let existingCamera = camera {
                activeCamera = existingCamera
            } else {
                guard let newCamera = try session.addCamera(config: streamConfig) else {
                    setError("Could not create glasses camera")
                    streamState = .stopped
                    return
                }
                camera = newCamera
                observeSession(newCamera.stream)
                activeCamera = newCamera
            }
            activeCamera.stream.start()
            updateStreamState(activeCamera.stream.state)
        } catch {
            setError("Could not start streaming: \(error.localizedDescription)")
            streamState = .stopped
        }
    }

    /// Waits up to `timeout` seconds for the glasses camera stream to reach `.streaming`
    /// (since `Stream.start()` transitions through `.starting`/`.waitingForDevice` asynchronously).
    public func waitForStreaming(timeout: TimeInterval = 5.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let stream = camera?.stream {
                updateStreamState(stream.state)
            }
            if streamState == .streaming || latestFrame != nil {
                return true
            }
            if case .error = streamState {
                return false
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if let stream = camera?.stream {
            updateStreamState(stream.state)
        }
        return streamState == .streaming || latestFrame != nil
    }

    /// Waits for a fresh camera frame to arrive on the active stream.
    public func waitForFreshFrame(maxWidth: CGFloat = 1280, quality: CGFloat = 0.75, timeout: TimeInterval = 4.5) async -> Data? {
        let initialSeq = frameSequence
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if frameSequence > initialSeq, let jpeg = currentFrameJPEG(maxWidth: maxWidth, quality: quality) {
                return jpeg
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return currentFrameJPEG(maxWidth: maxWidth, quality: quality)
    }

    public func stopStreaming() async {
        // Explicit stop clears intent so we don't auto-resume behind the user's back.
        wantsStreaming = false
        camera?.stop()
        camera = nil
        if !wantsConversationSpeech {
            deviceSession?.stop()
            deviceSession = nil
        }
        streamState = .stopped
        latestFrame = nil
    }

    private func observeSession(_ session: MWDATCamera.Stream) {
        stateToken = session.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in self?.updateStreamState(state) }
        }
        frameToken = session.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self, !self.isProcessingFrame else { return }
                self.isProcessingFrame = true
                defer { self.isProcessingFrame = false }
                if let image = frame.makeUIImage() {
                    self.latestFrame = image
                    self.frameSequence &+= 1
                }
            }
        }
        errorToken = session.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in self?.setError(String(describing: error)) }
        }
        photoToken = session.photoDataPublisher.listen { [weak self] photo in
            Task { @MainActor [weak self] in
                self?.photoContinuation?.resume(returning: photo.data)
                self?.photoContinuation = nil
            }
        }
    }

    private func updateStreamState(_ state: StreamState) {
        switch state {
        case .stopped: streamState = .stopped
        case .streaming: streamState = .streaming
        case .waitingForDevice, .starting, .stopping, .paused: streamState = .waiting
        default: streamState = .error(String(describing: state))
        }
    }

    // MARK: - Photo capture

    /// Captures a single JPEG photo from the glasses. Requires an active stream.
    public func capturePhoto(timeout: TimeInterval = 8) async throws -> Data {
        guard let stream = camera?.stream else { throw GlassesError.unavailable }
        if let existing = photoContinuation {
            existing.resume(throwing: GlassesError.superseded)
            photoContinuation = nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.photoContinuation = continuation
            guard stream.capturePhoto(format: .jpeg) else {
                self.photoContinuation = nil
                if let fallback = self.currentFrameJPEG() {
                    continuation.resume(returning: fallback)
                } else {
                    continuation.resume(throwing: GlassesError.unavailable)
                }
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let pending = self?.photoContinuation {
                    pending.resume(throwing: GlassesError.timeout)
                    self?.photoContinuation = nil
                }
            }
        }
    }

    /// The most recent video frame as JPEG. Used by the agent gateway's `camera.snap`.
    public func currentFrameJPEG(maxWidth: CGFloat = 1600, quality: CGFloat = 0.8) -> Data? {
        guard let frame = latestFrame else { return nil }
        return frame.scaledDown(maxWidth: maxWidth).jpegData(compressionQuality: quality)
    }

    private func setError(_ message: String) {
        lastError = message
        log.error("\(message, privacy: .public)")
    }

    deinit {
        sessionStateToken = nil; sessionErrorToken = nil
        stateToken = nil; frameToken = nil; errorToken = nil; photoToken = nil
        speechTranscriptToken = nil; speechStateToken = nil; speechErrorToken = nil
        voiceInvocationToken = nil; voiceErrorToken = nil
        voiceTask?.cancel(); deviceTask?.cancel(); registrationTask?.cancel()
        if let foregroundToken { NotificationCenter.default.removeObserver(foregroundToken) }
    }
}

public enum GlassesError: Error, LocalizedError {
    case timeout
    case superseded
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .timeout: return "Timed out waiting for the photo."
        case .superseded: return "A newer photo request replaced this one."
        case .unavailable: return "Glasses are not available."
        }
    }
}

extension UIImage {
    func scaledDown(maxWidth: CGFloat) -> UIImage {
        guard size.width > maxWidth else { return self }
        let scale = maxWidth / size.width
        let newSize = CGSize(width: maxWidth, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
