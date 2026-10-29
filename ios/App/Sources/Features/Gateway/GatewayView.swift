import SwiftUI
import DesignSystem
import AgentGateway
import Inject

struct GatewayView: View {
    @EnvironmentObject private var gateway: GatewayService
    @State private var portText = ""
    @ObserveInjection var inject
    @State private var tokenText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                HUDPanel {
                    HStack {
                        StatusBadge(statusLabel, color: statusColor)
                        Spacer()
                        Text(gateway.nodeID)
                            .font(Theme.Font.readout(12))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }

                VStack(spacing: Theme.Spacing.md) {
                    field("Host", text: $gateway.host)
                    field("Port", text: $portText, keyboard: .numberPad)
                    field("Token (optional)", text: $tokenText, secure: true)
                    Toggle("Use TLS (wss)", isOn: $gateway.useTLS)
                        .tint(Theme.Palette.accent)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }

                HUDButton(isConnected ? "Disconnect" : "Connect", systemImage: isConnected ? "bolt.slash" : "bolt") {
                    if let p = Int(portText) { gateway.port = p }
                    gateway.token = tokenText
                    isConnected ? gateway.disconnect() : gateway.connect()
                }

                Text("Works with Antigravity and OpenClaw gateways. Your glasses join as a node — the agent can run camera.snap and device.status.")
                    .font(Theme.Font.body(13))
                    .foregroundStyle(Theme.Palette.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("Agent Link")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
        .enableInjection()
        .onAppear { portText = String(gateway.port); tokenText = gateway.token }
    }

    private var isConnected: Bool {
        if case .connected = gateway.state { return true }
        return false
    }

    private var statusLabel: String {
        switch gateway.state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .waitingForPairing: return "awaiting pairing"
        case .error: return "error"
        }
    }

    private var statusColor: Color {
        switch gateway.state {
        case .connected: return Theme.Palette.positive
        case .connecting, .waitingForPairing: return Theme.Palette.accent
        case .error: return Theme.Palette.live
        case .disconnected: return Theme.Palette.textMuted
        }
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title.uppercased()).font(Theme.Font.readout(10)).tracking(1).foregroundStyle(Theme.Palette.textMuted)
            Group {
                if secure { SecureField(title, text: text) }
                else { TextField(title, text: text).keyboardType(keyboard) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(Theme.Spacing.md)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .foregroundStyle(Theme.Palette.textPrimary)
        }
    }
}
