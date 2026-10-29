import SwiftUI
import SwiftData
import GlassesKit

@main
struct MetaModApp: App {
    @StateObject private var glasses: GlassesService
    @StateObject private var providers = ProviderManager.shared
    @StateObject private var gateway: GatewayService
    @StateObject private var hermes: HermesService
    @StateObject private var router = AppRouter.shared
    /// One shared assistant session, used by the wake word AND by `LiveAIView`,
    /// so a wake-started conversation can exist without that screen being open.
    @StateObject private var session = RealtimeSession()
    @StateObject private var wakeListener = WakeWordListener.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let glassesService = GlassesService()
        let gatewayService = GatewayService(glasses: glassesService)
        _glasses = StateObject(wrappedValue: glassesService)
        _gateway = StateObject(wrappedValue: gatewayService)
        _hermes = StateObject(wrappedValue: HermesService())
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(glasses)
                .environmentObject(providers)
                .environmentObject(gateway)
                .environmentObject(hermes)
                .environmentObject(router)
                .environmentObject(session)
                .environmentObject(wakeListener)
                .onOpenURL { url in glasses.handleCallbackURL(url) }
                .onAppear(perform: configureWake)
        }
        .modelContainer(for: VisionRecord.self)
        .onChange(of: scenePhase) { _, phase in
            // Start listening when we come to the foreground; keep listening in the
            // background/locked (the active audio session keeps us alive). We only
            // stop when the user turns the toggle off.
            if phase == .active {
                if wakeListener.enabled { wakeListener.start() }
                hermes.resyncOnForeground()
            }
        }
    }

    private func configureWake() {
        let session = self.session
        let hermes = self.hermes
        // A saved pairing is only configuration; do not advertise agent controls
        // to Gemini until the phone has a live authenticated socket to Hermes.
        if hermes.isConfigured { hermes.connect() }
        let startVoiceSession: @MainActor () -> Void = {
            router.liveAIWoke = true // surface the Live AI sheet if/when foregrounded
            if session.status != .connecting && session.status != .live {
                if hermes.antigravityEnabled && hermes.isConfigured && hermes.state == .disconnected { hermes.connect() }
                let agyActive = hermes.antigravityEnabled && hermes.isConfigured
                session.start(
                    instructions: LiveAIMode.standard.instructions + GlassesTools.instructionsAddendum + HermesTools.instructionsAddendum(for: hermes.selectedInstance, antigravityEnabled: agyActive),
                    providers: providers, glasses: glasses,
                    injectFrames: false,
                    tools: GlassesTools.all + HermesTools.activeTools(antigravityEnabled: agyActive))
            }
        }
        wakeListener.onWake = startVoiceSession
        glasses.onVoiceInvocation = {
            print("[Code] Glasses Voice Invocation ('Hey Meta, start/open Code') received — starting Live AI")
            fflush(stdout)
            startVoiceSession()
        }
        // Voice commands route through Antigravity handoff; late replies get spoken when they land.
        session.toolHandler = { [weak hermes] name, argumentsJSON in
            await hermes?.handleToolCall(name: name, argumentsJSON: argumentsJSON)
                ?? #"{"error":"Antigravity bridge is not available"}"#
        }
        hermes.onLateReply = { [weak session] reply in
            session?.announce(reply)
        }
        if wakeListener.enabled {
            wakeListener.start()
        }
        if ProcessInfo.processInfo.environment["SUPERMETA_AUTOTEST_VOICE"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                print("[SuperMeta] Autotest: starting Live session via onWake()")
                fflush(stdout)
                wakeListener.onWake?()
            }
        }
    }
}
