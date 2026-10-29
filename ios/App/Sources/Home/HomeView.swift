import SwiftUI
import SwiftData
import DesignSystem
import GlassesKit
import Inject

/// The feature hub — a light "NEURA" dashboard: a hero Live AI card, real-data
/// stat cards, and grouped feature sections.
struct HomeView: View {
    @EnvironmentObject private var glasses: GlassesService
    @EnvironmentObject private var providers: ProviderManager
    @EnvironmentObject private var hermes: HermesService
    @EnvironmentObject private var session: RealtimeSession
    @Query(sort: \VisionRecord.createdAt, order: .reverse) private var records: [VisionRecord]
    @State private var showSettings = false
    @State private var showConnect = false
    @State private var connectShownOnce = false
    @ObserveInjection var inject

    /// Auto-present the connect sheet once per launch when the glasses aren't linked.
    private func maybeShowConnect() {
        if ProcessInfo.processInfo.environment["UI_PREVIEW"] != nil { return }
        guard glasses.isAvailable, glasses.registration == .notRegistered, !connectShownOnce else { return }
        connectShownOnce = true
        showConnect = true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    header

                    NavigationLink { LiveAIView() } label: { heroCard }
                        .buttonStyle(.plain)

                    statRow

                    section("Glasses Camera & Vision") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Spacing.md) {
                                NavigationLink { QuickVisionView() } label: {
                                    visionTile("Quick Vision", "Snap & recognize", "camera.viewfinder", Theme.Palette.ink)
                                }.buttonStyle(.plain)
                                NavigationLink { VisionRecognitionView() } label: {
                                    visionTile("Vision Chat", "Ask camera anything", "bubble.left.and.text.bubble.right", Theme.Palette.positive)
                                }.buttonStyle(.plain)
                                NavigationLink { LeanEatView() } label: {
                                    visionTile("LeanEat", "Meal nutrition", "leaf", Theme.Palette.live)
                                }.buttonStyle(.plain)
                                Button { showConnect = true } label: {
                                    visionTile("Connect Glasses", glasses.hasActiveDevice ? "Connected" : "Link Ray-Ban Meta", "eyeglasses", Theme.Palette.accent)
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                        }
                        .padding(.horizontal, -Theme.Spacing.lg)
                    }

                    section("Antigravity & Tools") {
                        VStack(spacing: Theme.Spacing.md) {
                            NavigationLink { HermesView() } label: {
                                antigravityCard
                            }.buttonStyle(.plain)
                            HStack(spacing: Theme.Spacing.md) {
                                NavigationLink { LiveTranslateView() } label: {
                                    tile("Live Translate", "Real-time speech", "waveform.badge.mic", Theme.Palette.ink)
                                }.buttonStyle(.plain)
                                NavigationLink { GatewayView() } label: {
                                    tile("Agent Link", "Camera node", "antenna.radiowaves.left.and.right", Theme.Palette.positive)
                                }.buttonStyle(.plain)
                                NavigationLink { RTMPStreamView() } label: {
                                    tile("Live Stream", "Broadcast RTMP", "dot.radiowaves.left.and.right", Theme.Palette.live)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationBarHidden(true)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showConnect) {
                ConnectGlassesView().environmentObject(glasses)
            }
            .onAppear { maybeShowConnect() }
            .onChange(of: glasses.registration) { _, _ in maybeShowConnect() }
        }
        .preferredColorScheme(.light)
        .enableInjection()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image("Logomark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 26)
                    Text("Super Meta")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                connectionChip
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Theme.Palette.surface))
                    .overlay(Circle().strokeBorder(Theme.Palette.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
            }
        }
    }

    private var connectionChip: some View {
        Button {
            showConnect = true
        } label: {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                Text(connectionText).font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary)
                Text(glasses.registration == .registered ? "· Manage" : "· Connect")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        if glasses.hasActiveDevice { return Theme.Palette.positive }
        if glasses.registration == .registered { return Theme.Palette.accent }
        return Theme.Palette.textMuted
    }

    private var connectionText: String {
        if !glasses.isAvailable { return "No glasses · using photos" }
        switch glasses.registration {
        case .registered:
            return glasses.hasActiveDevice ? "Glasses connected" : "Linked · turn on glasses"
        case .registering:
            return "Connecting…"
        default:
            return "Glasses not linked"
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(alignment: .top) {
                    StatusBadge(
                        session.status == .live ? "Live Session" : (glasses.hasActiveDevice ? "Glasses Ready" : "Vertex AI Ultra"),
                        color: session.status == .live ? Theme.Palette.live : Theme.Palette.positive
                    )
                    Spacer()
                    heroGlyph
                }
                Spacer(minLength: Theme.Spacing.sm)
                Text("Live AI")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Real-time voice & on-demand vision powered by Gemini 3.8 Live on Google AI Ultra — with direct lab-exec code execution\(hermes.antigravityEnabled ? " + Antigravity (\(hermes.selectedInstance.title))" : "").")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Spacing.xs) {
                    pillBadge(providers.realtimeModel == "gemini-3.8-live" ? "Gemini 3.8 Live" : "Gemini 2.5 Live", icon: "sparkles")
                    pillBadge("Voice · \(providers.realtimeVoice)", icon: "waveform")
                    pillBadge(hermes.antigravityEnabled ? "lab-exec + \(hermes.selectedInstance.shortLabel)" : "lab-exec", icon: "terminal")
                }
                HStack(spacing: Theme.Spacing.sm) {
                    Text(session.status == .live ? "Open Live Session" : "Start Live AI")
                        .font(.system(size: 15, weight: .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .background(Capsule().fill(Theme.Palette.ink))
                .padding(.top, Theme.Spacing.xs)
            }
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        }
    }

    private func pillBadge(_ label: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(Theme.Font.readout(10))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.Palette.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.Palette.surfaceHigh))
    }

    private var antigravityCard: some View {
        HStack(spacing: Theme.Spacing.md) {
            iconBadge("sparkles.rectangle.stack.fill", Theme.Palette.ink)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Antigravity")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Circle()
                        .fill(hermes.state == .connected ? Theme.Palette.positive : Theme.Palette.textMuted)
                        .frame(width: 6, height: 6)
                    Text(hermes.selectedInstance.title)
                        .font(Theme.Font.readout(11))
                        .foregroundStyle(Theme.Palette.positive)
                        .lineLimit(1)
                }
                Text("Remote coding agent · \(hermes.selectedInstance.subtitle)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .modifier(CardSurface())
    }

    /// The glasses' latest camera frame if we have one, otherwise a mic glyph.
    @ViewBuilder private var heroGlyph: some View {
        if let frame = glasses.latestFrame {
            Image(uiImage: frame)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        } else {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Theme.Palette.surfaceHigh))
        }
    }

    // MARK: Stat row (real data only)

    private var statRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            StatCard(value: "\(records.count)", label: "Records", systemImage: "square.stack.3d.up")
            StatCard(value: "\(weekCount)", label: "This week", systemImage: "calendar")
            Button { showConnect = true } label: {
                StatCard(
                    value: connectionValue,
                    label: "Glasses",
                    tint: glasses.hasActiveDevice ? Theme.Palette.positive : Theme.Palette.textSecondary,
                    systemImage: "eyeglasses"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var weekCount: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        return records.filter { $0.createdAt >= cutoff }.count
    }

    private var connectionValue: String {
        if glasses.hasActiveDevice { return "Live" }
        if glasses.registration == .registered { return "Linked" }
        return "Off"
    }

    // MARK: Section scaffolding

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
            content()
        }
    }

    private func wideCard(_ title: String, _ subtitle: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            iconBadge(icon, tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Palette.textMuted)
        }
        .modifier(CardSurface())
    }

    private func tile(_ title: String, _ subtitle: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            iconBadge(icon, tint)
            Spacer()
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .modifier(CardSurface())
    }

    private func visionTile(_ title: String, _ subtitle: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            iconBadge(icon, tint)
            Spacer()
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(width: 150, height: 118, alignment: .topLeading)
        .modifier(CardSurface())
    }

    private func iconBadge(_ icon: String, _ tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint == Theme.Palette.ink ? Color.white : tint)
            .frame(width: 38, height: 38)
            .background(Circle().fill(tint == Theme.Palette.ink ? Theme.Palette.ink : tint.opacity(0.14)))
    }
}

/// White card chrome shared by the Home tiles — surface fill, hairline border, soft shadow.
private struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(Theme.Palette.surface)
                    .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )
    }
}
