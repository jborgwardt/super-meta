import SwiftUI
import DesignSystem
import AgentGateway
import VisionKit
import Inject

/// Pair with the Antigravity Bridge server. The Bearer token is stored in the
/// Keychain; Gemini Live delegates coding jobs through this authenticated connection.
struct HermesPairingView: View {
    @EnvironmentObject private var hermes: HermesService
    @EnvironmentObject private var gateway: GatewayService
    @Environment(\.dismiss) private var dismiss
    @ObserveInjection var inject

    @State private var endpointText = ""
    @State private var errorText: String?
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Text("Paste your Antigravity Bridge address. Gemini Live sends coding jobs and tool requests to Antigravity through this authenticated connection.")
                        .font(Theme.Font.body(14))
                        .foregroundStyle(Theme.Palette.textSecondary)

                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("BRIDGE URL")
                            .font(Theme.Font.readout(10)).tracking(1)
                            .foregroundStyle(Theme.Palette.textMuted)
                        TextField("http://100.64.0.18:7195#token=…", text: $endpointText, axis: .vertical)
                            .lineLimit(1...3)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .padding(Theme.Spacing.md)
                            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(Theme.Font.body(13))
                            .foregroundStyle(Theme.Palette.live)
                    }

                    HUDButton("Connect", systemImage: "bolt") { applyEndpoint(endpointText) }

                    if DataScannerViewController.isSupported {
                        Button {
                            showScanner = true
                        } label: {
                            HStack {
                                Image(systemName: "qrcode.viewfinder")
                                Text("Scan QR code instead")
                            }
                            .font(Theme.Font.body(14))
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(maxWidth: .infinity)
                        }
                    }

                    Text("Use Antigravity Bridge behind Tailscale or an authenticated endpoint. Do not expose the bridge directly to the public internet.")
                        .font(Theme.Font.body(12))
                        .foregroundStyle(Theme.Palette.textMuted)
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("Pair with Antigravity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                showScanner = false
                endpointText = code
                applyEndpoint(code)
            }
        }
        .preferredColorScheme(.light)
        .enableInjection()
    }

    private func applyEndpoint(_ raw: String) {
        guard let endpoint = Self.parseEndpoint(raw) else {
            errorText = "Couldn't read that address. Expected something like http://100.64.0.18:7195#token=…"
            return
        }
        errorText = nil
        hermes.host = endpoint.host
        hermes.port = endpoint.port
        hermes.useTLS = endpoint.tls
        if let token = endpoint.token { hermes.token = token }
        hermes.connect()
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if hermes.state == .connected { dismiss() }
        }
    }

    /// Accepts `https://host:port#token=…`, `http://host:port?token=…`, or a
    /// bare `host[:port]` (the Antigravity Bridge defaults to port 7195).
    static func parseEndpoint(_ raw: String) -> (host: String, port: Int, tls: Bool, token: String?)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty else {
            return nil
        }

        var token = components.queryItems?.first(where: { $0.name == "token" })?.value
        // The dashboard puts the token in the fragment so it never hits server logs.
        if token == nil, let fragment = components.fragment {
            token = URLComponents(string: "?" + fragment)?
                .queryItems?.first(where: { $0.name == "token" })?.value
            if token == nil, !fragment.contains("=") { token = fragment }
        }

        // Control UI dev links carry the real endpoint in ?gatewayUrl=…
        if let nested = components.queryItems?.first(where: { $0.name == "gatewayUrl" })?.value,
           let inner = parseEndpoint(nested) {
            return (inner.host, inner.port, inner.tls, token ?? inner.token)
        }

        let tls = components.scheme == "wss" || components.scheme == "https"
        let port = components.port ?? (tls ? 443 : 7195)
        return (host, port, tls, token)
    }
}

// MARK: - QR scanner

private struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case let .barcode(barcode) = item, let payload = barcode.payloadStringValue {
                    dataScanner.stopScanning()
                    onCode(payload)
                    return
                }
            }
        }
    }
}
