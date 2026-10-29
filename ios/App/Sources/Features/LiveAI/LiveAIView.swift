import SwiftUI
import DesignSystem
import GlassesKit
import Inject

struct LiveAIView: View {
    @EnvironmentObject private var providers: ProviderManager
    @EnvironmentObject private var glasses: GlassesService
    // Shared assistant session (owned by MetaModApp) so this view shows whatever
    // the session is doing — including a wake-word-started conversation.
    @EnvironmentObject private var session: RealtimeSession
    @EnvironmentObject private var hermes: HermesService
    /// Persisted so a glasses "Hey Meta, open Code" launch starts Live AI with
    /// the same mode the Start Live AI button would use, not always Chat.
    @AppStorage("liveai_mode") private var mode: LiveAIMode = .standard
    @State private var showConnectGlasses = false
    @ObserveInjection var inject

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            liveCapabilitiesBar
            modePicker
            if session.isCameraActive {
                cameraPreviewCard
            }
            transcriptArea
            Spacer(minLength: Theme.Spacing.xs)
            controlButton
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("Live AI")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showConnectGlasses) {
            ConnectGlassesView().environmentObject(glasses)
        }
        .preferredColorScheme(.light)
        .enableInjection()
        // No onDisappear stop: the session is shared and may have been started by
        // the wake word. The Stop button and app termination end it.
    }

    private var liveCapabilitiesBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    showConnectGlasses = true
                } label: {
                    capabilityChip(
                        icon: "eyeglasses",
                        text: glasses.hasActiveDevice ? "Glasses Connected" : (glasses.registration == .registered ? "Glasses Linked" : "Connect Glasses"),
                        tint: glasses.hasActiveDevice ? Theme.Palette.positive : Theme.Palette.accent
                    )
                }
                .buttonStyle(.plain)

                capabilityChip(
                    icon: session.isCameraActive ? "video.fill" : "video.slash",
                    text: session.isCameraActive ? "Camera On" : "Cam Off · Ask Gemini",
                    tint: session.isCameraActive ? Theme.Palette.live : Theme.Palette.textMuted
                )

                Menu {
                    ForEach(SettingsView.liveModels, id: \.id) { opt in
                        Button {
                            providers.realtimeModel = opt.id
                        } label: {
                            HStack {
                                Text(opt.title)
                                if providers.realtimeModel == opt.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    capabilityChip(
                        icon: "sparkles",
                        text: providers.realtimeModel == "gemini-3.8-live" ? "Gemini 3.8 Live · Ultra" : "Gemini 2.5 Live",
                        tint: Theme.Palette.positive
                    )
                }

                Menu {
                    ForEach(ProviderManager.availableVoices) { voice in
                        Button {
                            providers.realtimeVoice = voice.id
                        } label: {
                            HStack {
                                Text("\(voice.name) — \(voice.tagline)")
                                if providers.realtimeVoice == voice.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    capabilityChip(
                        icon: "waveform",
                        text: "Voice: \(providers.realtimeVoice)",
                        tint: Theme.Palette.textPrimary
                    )
                }

                Menu {
                    Button {
                        hermes.antigravityEnabled = false
                    } label: {
                        HStack {
                            Text("Lab Exec Only (Direct · No Antigravity)")
                            if !hermes.antigravityEnabled {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Divider()
                    ForEach(AntigravityInstance.allCases) { instance in
                        Button {
                            hermes.antigravityEnabled = true
                            hermes.selectedInstance = instance
                        } label: {
                            HStack {
                                Text("Lab Exec + Antigravity: \(instance.title)")
                                if hermes.antigravityEnabled && hermes.selectedInstance == instance {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    capabilityChip(
                        icon: "terminal.fill",
                        text: hermes.antigravityEnabled ? "lab-exec + \(hermes.selectedInstance.shortLabel)" : "lab-exec (Direct)",
                        tint: Theme.Palette.positive
                    )
                }
            }
        }
    }

    private var cameraPreviewCard: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Palette.surface)
                .frame(height: 170)
            if let frame = glasses.latestFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 170)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    ProgressView()
                    Text("Starting glasses camera…")
                        .font(Theme.Font.readout(12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 170)
            }
            StatusBadge("Glasses Camera Live", color: Theme.Palette.live)
                .padding(Theme.Spacing.sm)
        }
    }

    private func capabilityChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(Theme.Font.readout(11))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.Palette.surface))
        .overlay(Capsule().strokeBorder(Theme.Palette.border, lineWidth: 1))
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(LiveAIMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .disabled(session.status == .live || session.status == .connecting)
    }

    private var transcriptArea: some View {
        HUDPanel {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    if !session.userLine.isEmpty {
                        Text("You: \(session.userLine)")
                            .font(Theme.Font.readout(12))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Text(session.transcript.isEmpty ? statusText : session.transcript)
                        .font(Theme.Font.body(16))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        }
    }

    private var statusText: String {
        switch session.status {
        case .idle:
            let execTarget = hermes.antigravityEnabled
                ? "lab-exec (direct) + Antigravity (\(hermes.selectedInstance.title))"
                : "lab-exec direct (vps, mac, panzer, pi, ha)"
            return "Ready on \(providers.realtimeModel == "gemini-3.8-live" ? "Gemini 3.8 Live (Vertex AI Ultra)" : providers.realtimeModel) with \(providers.realtimeVoice) voice.\nCode execution: \(execTarget).\nCamera stays off unless you ask Gemini."
        case .connecting: return "Connecting to Vertex AI Ultra Live relay…"
        case .live: return "Listening… Ask a question, ask Gemini to turn on the camera, or run code via lab-exec / Antigravity."
        case let .error(message): return message
        }
    }

    private var controlButton: some View {
        HUDButton(buttonTitle, systemImage: isActive ? "stop.fill" : "mic.fill") {
            if isActive { session.stop() }
            else {
                if hermes.antigravityEnabled && hermes.isConfigured && hermes.state == .disconnected { hermes.connect() }
                let agyActive = hermes.antigravityEnabled && hermes.isConfigured
                session.start(
                    instructions: mode.instructions + GlassesTools.instructionsAddendum + HermesTools.instructionsAddendum(for: hermes.selectedInstance, antigravityEnabled: agyActive),
                    providers: providers, glasses: glasses,
                    injectFrames: false,
                    tools: GlassesTools.all + HermesTools.activeTools(antigravityEnabled: agyActive))
            }
        }
    }

    private var isActive: Bool { session.status == .live || session.status == .connecting }
    private var buttonTitle: String { isActive ? "Stop" : "Start Live AI" }
}

enum LiveAIMode: String, CaseIterable, Identifiable {
    case standard, code, museum, accessibility
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "Chat"
        case .code: return "Code"
        case .museum: return "Guide"
        case .accessibility: return "Assist"
        }
    }
    var instructions: String {
        switch self {
        case .standard:
            return "You are Super Meta, a sharp, low-latency voice and vision co-pilot for Justin wearing smart glasses, powered by Gemini 3.8 Live on Google AI Ultra and paired with his Antigravity coding environment. Keep replies concise, natural, and spoken-friendly. The camera stays off unless he explicitly asks you to look or take a photo."
        case .code:
            return "You are Justin's voice-first software architect and Antigravity pair programmer on smart glasses. When he describes a coding task, bug fix, script, or repo change, dispatch it immediately to his selected Antigravity instance and report back crisply when it finishes."
        case .museum:
            return "You are a knowledgeable museum and travel guide. When you see an image of an artwork, landmark, or object, explain what it is and share interesting context. Keep it concise and spoken-friendly."
        case .accessibility:
            return "You assist a visually impaired person wearing camera glasses. Describe scenes, read text, identify objects and hazards clearly and practically when you receive an image."
        }
    }
}
