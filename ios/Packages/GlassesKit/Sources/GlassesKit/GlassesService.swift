import Foundation
import UIKit
import MWDATCore
import MWDATCamera
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

    // MARK: SDK handles (nil when the SDK isn't configured)
    private var wearables: WearablesInterface?
    private var deviceSelector: AutoDeviceSelector?
    private var deviceSession: DeviceSession?
    private var camera: MWDATCamera.Camera?
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
    private var deviceTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var isProcessingFrame = false
    private var frameSequence: UInt64 = 0
    private var photoContinuation: CheckedContinuation<Data, Error>?

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
        let selector = AutoDeviceSelector(wearables: wearables)
        self.streamConfig = StreamConfiguration(
            videoCodec: VideoCodec.raw,
            resolution: quality.sdkResolution,
            frameRate: 24
        )

        self.wearables = wearables
        self.deviceSelector = selector
        self.isAvailable = true
        self.streamState = .stopped

        observeRegistration(wearables)
        observeDevice(selector)
        observeAppLifecycle()
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
            log.error("Meta AI DAT registration failed: \(String(describing: error))")
            setError("Registration failed: \(error.localizedDescription)")
        }
    }

    /// Unlinks the app from the glasses (the connect toggle turned off).
    public func startUnregistration() async {
        guard let wearables else { return }
        do { try await wearables.startUnregistration() }
        catch { setError("Couldn't disconnect: \(error.localizedDescription)") }
    }

    /// Completes registration / permission flows. Call from `.onOpenURL` — the Meta
    /// app redirects back to `metamod://…?metaWearablesAction=…` and the SDK finishes
    /// the handshake here.
    public func handleCallbackURL(_ url: URL) {
        guard let wearables else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard components?.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
        log.info("Received Meta AI DAT callback URL")
        Task { @MainActor in
            do {
                let handled = try await wearables.handleUrl(url)
                log.info("Meta AI DAT callback handled=\(handled)")
            } catch {
                log.error("Meta AI DAT callback failed: \(String(describing: error))")
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

    // MARK: - Device

    private func observeDevice(_ selector: AutoDeviceSelector) {
        deviceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await device in selector.activeDeviceStream() {
                let connected = (device != nil)
                NSLog("[Glasses] activeDeviceStream connected=\(connected)")
                // Connection status is owned here — activeDeviceStream is the SDK's
                // canonical "is a device active" signal (matches the reference app).
                self.hasActiveDevice = connected
                if connected, self.wantsStreaming, !self.isStreaming {
                    await self.startStreaming()
                }
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
                guard let self, self.wantsStreaming, !self.isStreaming else { return }
                await self.startStreaming()
            }
        }
    }

    // MARK: - Streaming

    public func startStreaming() async {
        guard let wearables, let deviceSelector else { return }
        if let existingCamera = camera, existingCamera.stream.state == .streaming {
            return
        }
        // Mark intent up front so an interrupted stream auto-resumes even if the
        // device isn't ready yet (session parks in `waitingForDevice`).
        wantsStreaming = true
        lastError = nil
        streamState = .waiting
        do {
            let session: DeviceSession
            if let existing = deviceSession, existing.state != .stopped, existing.state != .stopping {
                session = existing
            } else {
                if let knownId = wearables.devices.first {
                    session = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: knownId))
                } else {
                    session = try wearables.createSession(deviceSelector: deviceSelector)
                }
                deviceSession = session
                sessionStateToken = session.statePublisher.listen { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if state == .stopped {
                            self.camera = nil
                            self.deviceSession = nil
                            self.latestFrame = nil
                            self.streamState = .stopped
                        }
                    }
                }
                sessionErrorToken = session.errorPublisher.listen { [weak self] error in
                    Task { @MainActor [weak self] in
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
                setError("Glasses session did not start (state=\(String(describing: session.state)))")
                session.stop()
                deviceSession = nil
                streamState = .stopped
                return
            }

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
        deviceSession?.stop()
        deviceSession = nil
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
        deviceTask?.cancel(); registrationTask?.cancel()
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
