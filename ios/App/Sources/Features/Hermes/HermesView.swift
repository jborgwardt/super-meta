import SwiftUI
import DesignSystem
import AgentGateway
import Inject

/// Command center for the remote Antigravity coding agent: switch between remote
/// instances (`desktop-void-mars`, `justins-macbook-pro-local-solar-axis`, `VPS (100.64.0.18)`),
/// inspect active sessions, and dispatch coding tasks or messages.
struct HermesView: View {
    @EnvironmentObject private var hermes: HermesService
    @EnvironmentObject private var gateway: GatewayService
    @ObserveInjection var inject

    @State private var draft = ""
    @State private var errorText: String?
    @State private var showPairing = false
    @State private var showTaskSheet = false
    @State private var showMessageSheet = false
    @State private var showInstanceSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.md)

            instanceToggleBar
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.sm)

            if let connectionHint {
                Text(connectionHint)
                    .font(Theme.Font.body(12))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.top, Theme.Spacing.sm)
            }

            if !hermes.sessions.isEmpty {
                sessionStrip
                    .padding(.top, Theme.Spacing.md)
            }

            transcript

            if let errorText {
                Text(errorText)
                    .font(Theme.Font.body(12))
                    .foregroundStyle(Theme.Palette.live)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.xs)
            }

            quickActions
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.sm)

            inputBar
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.md)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("Antigravity")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showPairing) { HermesPairingView() }
        .sheet(isPresented: $showTaskSheet) { SpawnTaskSheet() }
        .sheet(isPresented: $showMessageSheet) { ChannelMessageSheet() }
        .sheet(isPresented: $showInstanceSheet) {
            RemoteInstancePickerSheet(selectedInstance: $hermes.selectedInstance)
                .presentationDetents([.height(310), .medium])
        }
        .enableInjection()
        .onAppear {
            if hermes.isConfigured {
                hermes.connect()
                Task { await hermes.refreshSessions() }
            } else {
                showPairing = true
            }
        }
        .onChange(of: hermes.state) { _, newState in
            if newState == .waitingForPairing { showPairing = true }
        }
    }

    // MARK: Header & Remote Instance Toggle

    private var header: some View {
        HStack {
            StatusBadge(statusLabel, color: statusColor)
            Button {
                showInstanceSheet = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.Palette.positive)
                        .frame(width: 7, height: 7)
                    Text(hermes.selectedInstance.title)
                        .font(Theme.Font.readout(12))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .strokeBorder(Theme.Palette.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Spacer()
            if hermes.state != .connected {
                Button("Pair") { showPairing = true }
                    .font(Theme.Font.readout(13))
                    .foregroundStyle(Theme.Palette.accent)
            } else {
                Button {
                    Task { await hermes.refreshSessions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
    }

    private var instanceToggleBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("REMOTE INSTANCE", systemImage: "folder")
                    .font(Theme.Font.readout(10))
                    .foregroundStyle(Theme.Palette.textMuted)
                Spacer()
                Text(hermes.selectedInstance.subtitle)
                    .font(Theme.Font.readout(10))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            Picker("Remote Instance", selection: $hermes.selectedInstance) {
                ForEach(AntigravityInstance.allCases) { instance in
                    Text(instance.shortLabel).tag(instance)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
    }

    private var statusLabel: String {
        switch hermes.state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .waitingForPairing: return "awaiting approval"
        case .error: return "error"
        }
    }

    private var statusColor: Color {
        switch hermes.state {
        case .connected: return Theme.Palette.positive
        case .connecting, .waitingForPairing: return Theme.Palette.accent
        case .error: return Theme.Palette.live
        case .disconnected: return Theme.Palette.textMuted
        }
    }

    private var connectionHint: String? {
        if case let .error(message) = hermes.state { return message }
        guard hermes.state != .connected else { return nil }
        let host = hermes.host.lowercased()
        if host == "127.0.0.1" || host == "localhost" || host == "::1" {
            return "This address points to the iPhone, not your VPS. Pair a reachable, authenticated Antigravity Bridge URL to connect controls."
        }
        return nil
    }

    // MARK: Sessions

    private var sessionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(hermes.sessions) { session in
                    sessionChip(session)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private func sessionChip(_ session: AgentSessionInfo) -> some View {
        let focused = sessionKeysMatch(session.key, hermes.focusedSessionKey)
        return Button {
            Task { await hermes.selectSession(session) }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(focused ? Theme.Palette.positive : Theme.Palette.textMuted)
                    .frame(width: 6, height: 6)
                Text(session.label)
                    .font(Theme.Font.readout(12))
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(focused ? Theme.Palette.accent.opacity(0.22) : Theme.Palette.surface)
            )
            .overlay(
                Capsule().strokeBorder(focused ? Theme.Palette.accent : .clear, lineWidth: 1)
            )
            .foregroundStyle(focused ? Theme.Palette.accent : Theme.Palette.textSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.md) {
                    if hermes.messages.isEmpty && hermes.streamingReply.isEmpty {
                        emptyState.padding(.top, Theme.Spacing.xl)
                    }
                    ForEach(hermes.messages) { message in
                        bubble(message)
                    }
                    if !hermes.streamingReply.isEmpty {
                        streamingBubble.id("streaming")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(Theme.Spacing.lg)
            }
            .onChange(of: hermes.messages) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: hermes.streamingReply) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Palette.textMuted)
            Text("Target: \(hermes.selectedInstance.title) (\(hermes.selectedInstance.workspaceLabel))\nAsk Antigravity to write or run code, spawn a background job, or tap a session above.")
                .font(Theme.Font.body(13))
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
        }
    }

    private func bubble(_ message: HermesChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .font(Theme.Font.body(15))
                .foregroundStyle(message.role == .system ? Theme.Palette.textMuted : Theme.Palette.textPrimary)
                .padding(Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill(message.role == .user ? Theme.Palette.accent.opacity(0.18) : Theme.Palette.surface)
                )
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var streamingBubble: some View {
        HStack {
            Text(hermes.streamingReply)
                .font(Theme.Font.body(15))
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
                .overlay(alignment: .bottomTrailing) {
                    ProgressView().scaleEffect(0.5).padding(6)
                }
            Spacer(minLength: 40)
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: Theme.Spacing.sm) {
            quickAction("New Job", "hammer") { showTaskSheet = true }
            quickAction("Instance", "server.rack") { showInstanceSheet = true }
            quickAction("Sync", "arrow.clockwise") {
                Task { await hermes.refreshSessions() }
            }
        }
    }

    private func quickAction(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(Theme.Font.readout(12))
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Theme.Palette.surface))
            .foregroundStyle(Theme.Palette.textSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            TextField("Message Antigravity (\(hermes.selectedInstance.shortLabel))…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.sentences)
                .padding(Theme.Spacing.md)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                .foregroundStyle(Theme.Palette.textPrimary)
                .onSubmit(sendDraft)
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(draft.isEmpty ? Theme.Palette.textMuted : Theme.Palette.accent)
            }
            .disabled(draft.isEmpty)
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        errorText = nil
        Task {
            do {
                try await hermes.ask(text)
            } catch let error as GatewayError {
                errorText = error.message
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - Remote Control Instances sheet

private struct RemoteInstancePickerSheet: View {
    @Binding var selectedInstance: AntigravityInstance
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AntigravityInstance.allCases) { instance in
                        Button {
                            selectedInstance = instance
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(instance == .vpsCLI ? Theme.Palette.textMuted : Theme.Palette.positive)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(instance.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                    Text(instance.subtitle)
                                        .font(Theme.Font.readout(11))
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                }
                                Spacer()
                                if selectedInstance == instance {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Remote Control Instances")
                }
            }
            .navigationTitle("Antigravity Instances")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.light)
    }
}

// MARK: - Spawn task sheet

private struct SpawnTaskSheet: View {
    @EnvironmentObject private var hermes: HermesService
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var repo = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Remote Instance") {
                    Picker("Target", selection: $hermes.selectedInstance) {
                        ForEach(AntigravityInstance.allCases) { instance in
                            Text(instance.title).tag(instance)
                        }
                    }
                }
                Section("Coding Task") {
                    TextField("What should Antigravity build or run?", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("Repository / Workspace (optional)") {
                    TextField(hermes.selectedInstance.workspaceLabel, text: $repo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let errorText {
                    Text(errorText).foregroundStyle(Theme.Palette.live)
                }
            }
            .navigationTitle("New Antigravity Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Starting…" : "Start") { start() }
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private func start() {
        busy = true
        errorText = nil
        Task {
            do {
                _ = try await hermes.spawnTask(
                    prompt: prompt,
                    repo: repo.isEmpty ? nil : repo,
                    label: nil)
                dismiss()
            } catch let error as GatewayError {
                errorText = error.message
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Channel message sheet

private struct ChannelMessageSheet: View {
    @EnvironmentObject private var hermes: HermesService
    @Environment(\.dismiss) private var dismiss
    @State private var channel = "telegram"
    @State private var recipient = ""
    @State private var text = ""
    @State private var busy = false
    @State private var errorText: String?

    private let channels = ["telegram", "whatsapp", "discord", "slack"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Channel") {
                    Picker("Channel", selection: $channel) {
                        ForEach(channels, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    TextField("Recipient (chat id, phone, @user)", text: $recipient)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Message") {
                    TextField("Message", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                }
                if let errorText {
                    Text(errorText).foregroundStyle(Theme.Palette.live)
                }
            }
            .navigationTitle("Send Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Sending…" : "Send") { send() }
                        .disabled(recipient.isEmpty || text.isEmpty || busy)
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private func send() {
        busy = true
        errorText = nil
        Task {
            do {
                try await hermes.sendChannelMessage(channel: channel, to: recipient, text: text)
                dismiss()
            } catch let error as GatewayError {
                errorText = error.message
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }
}
