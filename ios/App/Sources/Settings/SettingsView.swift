import SwiftUI
import DesignSystem
import AIProviders
import GlassesKit
import Inject

struct SettingsView: View {
    @EnvironmentObject private var providers: ProviderManager
    @EnvironmentObject private var glasses: GlassesService
    @EnvironmentObject private var wakeListener: WakeWordListener
    @EnvironmentObject private var hermes: HermesService
    @Environment(\.dismiss) private var dismiss
    @ObserveInjection var inject

    /// Hidden when embedded as a tab (there's no sheet to dismiss).
    var showsDoneButton = true

    struct ModelOption { let id: String; let title: String; let subtitle: String }
    /// Selectable Gemini Live models on Vertex AI (Google AI Ultra relay).
    static let liveModels: [ModelOption] = [
        .init(id: "gemini-3.8-live", title: "Gemini Live · 3.8 (Vertex Ultra)", subtitle: "Flagship low-latency voice & vision on Google AI Ultra"),
        .init(id: "gemini-live-2.5-flash-native-audio", title: "Gemini Live · 2.5 Flash Native Audio", subtitle: "Vertex AI native audio model")
    ]
    /// On-device Gemma models — shown disabled (local support coming soon).
    static let gemmaModels: [ModelOption] = [
        .init(id: "gemma-3n-e2b", title: "Gemma 4 · E2B", subtitle: "On-device · offline"),
        .init(id: "gemma-3n-e4b", title: "Gemma 4 · E4B", subtitle: "On-device · offline")
    ]

    var body: some View {
        NavigationStack {
            List {
                deviceSection
                antigravitySection
                providerSection
                voiceSection
                keysSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 90, for: .scrollContent)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }
                }
            }
        }
        .preferredColorScheme(.light)
        .enableInjection()
    }

    private func modelRow(_ title: String, _ subtitle: String, selected: Bool, trailing: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.Palette.textPrimary)
                Text(subtitle).font(Theme.Font.readout(11)).foregroundStyle(Theme.Palette.textMuted)
            }
            Spacer()
            if let trailing {
                Text(trailing).font(Theme.Font.readout(11)).foregroundStyle(Theme.Palette.textMuted)
            } else if selected {
                Image(systemName: "checkmark").foregroundStyle(Theme.Palette.accent)
            }
        }
    }

    private var antigravitySection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lab Exec (Direct)")
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("exec.heil.haus · vps, mac, panzer, pi, pihole, borgwardt, ha")
                        .font(Theme.Font.readout(11))
                        .foregroundStyle(Theme.Palette.textMuted)
                }
                Spacer()
                StatusBadge("active", color: Theme.Palette.positive)
            }

            Toggle("Enable Antigravity Handoff (Optional)", isOn: $hermes.antigravityEnabled)
                .tint(Theme.Palette.accent)

            if hermes.antigravityEnabled {
                ForEach(AntigravityInstance.allCases) { instance in
                    Button {
                        hermes.selectedInstance = instance
                    } label: {
                        modelRow(
                            instance.title,
                            instance.subtitle,
                            selected: hermes.selectedInstance == instance,
                            trailing: nil
                        )
                    }
                }
            }
        } header: { sectionHeader("Code Execution · Lab Exec & Antigravity") } footer: {
            Text("Gemini Live can always execute code, shell commands, and file reads/writes directly via lab-exec across your lab hosts. Enable Antigravity Handoff if you also want optional delegation to a remote Antigravity IDE instance.")
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .listRowBackground(Theme.Palette.surface)
        .foregroundStyle(Theme.Palette.textPrimary)
    }

    private var deviceSection: some View {
        Section {
            NavigationLink {
                ConnectGlassesView().environmentObject(glasses)
            } label: {
                HStack {
                    Text("Glasses")
                    Spacer()
                    StatusBadge(glassesStatus.0, color: glassesStatus.1)
                }
            }
        } header: { sectionHeader("Device") } footer: {
            Text("Tap to link or manage your Ray-Ban Meta glasses. During Live AI, ask Gemini to turn the camera on or off, look at what's in front of you, or take a photo.")
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .listRowBackground(Theme.Palette.surface)
        .foregroundStyle(Theme.Palette.textPrimary)
    }

    private var glassesStatus: (String, Color) {
        guard glasses.isAvailable else { return ("unavailable", Theme.Palette.textMuted) }
        switch glasses.registration {
        case .registered:
            return glasses.hasActiveDevice ? ("connected", Theme.Palette.positive) : ("linked · turn on glasses", Theme.Palette.accent)
        case .registering:
            return ("connecting…", Theme.Palette.accent)
        default:
            return ("not linked", Theme.Palette.textMuted)
        }
    }

    private var providerSection: some View {
        Section {
            Picker("Provider", selection: $providers.visionVendor) {
                ForEach(AIVendor.allCases, id: \.self) { vendor in
                    Text(vendor.displayName).tag(vendor)
                }
            }
            .tint(Theme.Palette.accent)

            NavigationLink {
                ModelPickerView(vendor: providers.visionVendor)
            } label: {
                HStack {
                    Text("Model")
                    Spacer()
                    Text(providers.model(for: providers.visionVendor))
                        .font(Theme.Font.readout(12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        } header: { sectionHeader("AI Provider") } footer: {
            Text("Used for image recognition and chat. Realtime voice uses Gemini Live — pick the model under Voice.")
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .listRowBackground(Theme.Palette.surface)
        .foregroundStyle(Theme.Palette.textPrimary)
    }

    private var voiceSection: some View {
        Section {
            ForEach(Self.liveModels, id: \.id) { model in
                Button {
                    providers.realtimeModel = model.id
                } label: {
                    modelRow(model.title, model.subtitle, selected: providers.realtimeModel == model.id, trailing: nil)
                }
            }
            ForEach(Self.gemmaModels, id: \.id) { model in
                modelRow(model.title, model.subtitle, selected: false, trailing: "Soon")
                    .foregroundStyle(Theme.Palette.textMuted)
            }

            Picker("Voice Persona", selection: $providers.realtimeVoice) {
                ForEach(ProviderManager.availableVoices) { voice in
                    Text("\(voice.name) · \(voice.tagline)").tag(voice.id)
                }
            }
            .tint(Theme.Palette.accent)

            Toggle("Wake word", isOn: $wakeListener.enabled)
                .tint(Theme.Palette.accent)

            if wakeListener.enabled {
                TextField("Wake phrase, e.g. hey gemini", text: $wakeListener.phrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        } header: { sectionHeader("Voice & Live AI") } footer: {
            Text("Say \"Hey Gemini\" or \"Hey Antigravity\" to start Live AI hands-free on your selected model — through the glasses when connected, even with the phone locked. Camera stays off unless you ask.")
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .listRowBackground(Theme.Palette.surface)
        .foregroundStyle(Theme.Palette.textPrimary)
    }

    private var keysSection: some View {
        Section {
            ForEach(AIVendor.allCases, id: \.self) { vendor in
                NavigationLink {
                    APIKeyEntryView(vendor: vendor)
                } label: {
                    HStack {
                        Text(vendor.displayName)
                        Spacer()
                        if providers.hasKey(for: vendor) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.Palette.positive)
                        } else {
                            Text("not set")
                                .font(Theme.Font.readout(12))
                                .foregroundStyle(Theme.Palette.textMuted)
                        }
                    }
                }
            }
        } header: { sectionHeader("API Keys") }
        .listRowBackground(Theme.Palette.surface)
        .foregroundStyle(Theme.Palette.textPrimary)
    }

    private var aboutSection: some View {
        Section {
            HStack { Text("Edition"); Spacer(); Text("Super Meta · Antigravity Ultra").foregroundStyle(Theme.Palette.textSecondary) }
            HStack { Text("Live Relay"); Spacer(); Text("Vertex AI (100.64.0.4:8796)").font(Theme.Font.readout(12)).foregroundStyle(Theme.Palette.textSecondary) }
            HStack { Text("Antigravity Bridge"); Spacer(); Text("100.64.0.18:7195").font(Theme.Font.readout(12)).foregroundStyle(Theme.Palette.textSecondary) }
            HStack { Text("Version"); Spacer(); Text("2.0.0").foregroundStyle(Theme.Palette.textSecondary) }
        } header: { sectionHeader("About") }
        .listRowBackground(Theme.Palette.surface)
        .foregroundStyle(Theme.Palette.textPrimary)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.Font.readout(11))
            .tracking(1.5)
            .foregroundStyle(Theme.Palette.textSecondary)
    }
}

/// Secure entry for one vendor's API key.
struct APIKeyEntryView: View {
    let vendor: AIVendor
    @EnvironmentObject private var providers: ProviderManager
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        List {
            Section {
                SecureField("Paste your \(vendor.displayName) API key", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(Theme.Palette.textPrimary)
            } footer: {
                Text(footerHint).foregroundStyle(Theme.Palette.textMuted)
            }
            .listRowBackground(Theme.Palette.surface)

            Section {
                Button("Save") {
                    providers.setAPIKey(draft, for: vendor)
                    dismiss()
                }
                .foregroundStyle(Theme.Palette.accent)
                if providers.hasKey(for: vendor) {
                    Button("Remove key", role: .destructive) {
                        providers.setAPIKey("", for: vendor)
                        draft = ""
                        dismiss()
                    }
                }
            }
            .listRowBackground(Theme.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(vendor.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = providers.apiKey(for: vendor) }
        .preferredColorScheme(.light)
    }

    private var footerHint: String {
        switch vendor {
        case .gemini: return "Get a key at aistudio.google.com/apikey"
        case .openAI: return "Get a key at platform.openai.com/api-keys"
        case .claude: return "Get a key at console.anthropic.com"
        case .openRouter: return "Get a key at openrouter.ai/keys"
        }
    }
}

/// Fetches and lists every model the provider exposes; tap to select.
/// Falls back to manual entry if there's no key or the fetch fails.
struct ModelPickerView: View {
    let vendor: AIVendor
    @EnvironmentObject private var providers: ProviderManager
    @Environment(\.dismiss) private var dismiss

    @State private var models: [AIModelInfo] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var search = ""
    @State private var manual = ""

    private var filtered: [AIModelInfo] {
        guard !search.isEmpty else { return models }
        return models.filter { $0.id.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if loading {
                Section { HStack { ProgressView().tint(Theme.Palette.accent); Text("Loading models…").foregroundStyle(Theme.Palette.textSecondary) } }
                    .listRowBackground(Theme.Palette.surface)
            }

            if let loadError {
                Section {
                    Text(loadError).font(Theme.Font.body(14)).foregroundStyle(Theme.Palette.live)
                    TextField("Model id", text: $manual)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Button("Use \"\(manual.isEmpty ? vendor.defaultModel : manual)\"") {
                        providers.setModel(manual.isEmpty ? vendor.defaultModel : manual, for: vendor); dismiss()
                    }.foregroundStyle(Theme.Palette.accent)
                } header: { Text("Manual entry") }
                .listRowBackground(Theme.Palette.surface)
            }

            if !models.isEmpty {
                Section {
                    ForEach(filtered) { model in
                        Button { providers.setModel(model.id, for: vendor); dismiss() } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.name).foregroundStyle(Theme.Palette.textPrimary)
                                    if model.name != model.id {
                                        Text(model.id).font(Theme.Font.readout(11)).foregroundStyle(Theme.Palette.textMuted)
                                    }
                                }
                                Spacer()
                                if providers.model(for: vendor) == model.id {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.Palette.accent)
                                }
                            }
                        }
                    }
                } header: { Text("\(models.count) models") }
                .listRowBackground(Theme.Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("\(vendor.displayName) Model")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Filter models")
        .preferredColorScheme(.light)
        .task { await load() }
    }

    private func load() async {
        let key = providers.apiKey(for: vendor)
        manual = providers.model(for: vendor)
        guard !key.isEmpty else {
            loadError = "Add your \(vendor.displayName) API key first to load the model list."
            return
        }
        loading = true
        defer { loading = false }
        do {
            models = try await listModels(vendor, apiKey: key)
            if models.isEmpty { loadError = "No models returned." }
        } catch {
            loadError = (error as? AIProviderError)?.errorDescription ?? error.localizedDescription
        }
    }
}
