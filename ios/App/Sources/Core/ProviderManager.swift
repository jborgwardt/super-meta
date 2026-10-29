import Foundation
import SwiftUI
import AIProviders

/// Owns the user's AI provider selection and API keys, and builds the active
/// `ChatVisionProvider` for vision/chat features. Keys live in the Keychain;
/// vendor + per-vendor model live in UserDefaults.
@MainActor
final class ProviderManager: ObservableObject {
    static let shared = ProviderManager()

    @Published var visionVendor: AIVendor {
        didSet { defaults.set(visionVendor.rawValue, forKey: Keys.visionVendor) }
    }

    /// Which provider powers Live AI realtime voice. Default: Gemini Live.
    @Published var realtimeVendor: AIVendor {
        didSet { defaults.set(realtimeVendor.rawValue, forKey: Keys.realtimeVendor) }
    }

    /// The realtime model Live AI / Live Translate connect to (per current vendor).
    @Published var realtimeModel: String {
        didSet { defaults.set(realtimeModel, forKey: Keys.realtimeModel) }
    }

    /// Selected HD voice persona for Gemini 3.8 Live.
    @Published var realtimeVoice: String {
        didSet { defaults.set(realtimeVoice, forKey: Keys.realtimeVoice) }
    }

    /// Default realtime model — the flagship Gemini 3.8 Live model on Vertex AI Ultra.
    static let defaultRealtimeModel = "gemini-3.8-live"
    static let defaultRealtimeVoice = "Aoede"

    /// Curated Gemini Live models offered on Vertex AI in Settings.
    static let knownRealtimeModels = ["gemini-3.8-live", "gemini-live-2.5-flash-native-audio"]

    struct VoiceOption: Identifiable, Equatable {
        let id: String
        let name: String
        let tagline: String
    }

    static let availableVoices: [VoiceOption] = [
        .init(id: "Aoede", name: "Aoede", tagline: "Warm, articulate & expressive (Default)"),
        .init(id: "Puck", name: "Puck", tagline: "Crisp, upbeat & energetic"),
        .init(id: "Kore", name: "Kore", tagline: "Calm, composed & clear"),
        .init(id: "Fenrir", name: "Fenrir", tagline: "Deep, grounded & direct"),
        .init(id: "Charon", name: "Charon", tagline: "Smooth, resonant & measured"),
        .init(id: "Zephyr", name: "Zephyr", tagline: "Breezy, natural & conversational"),
        .init(id: "Leda", name: "Leda", tagline: "Bright, friendly & poised"),
        .init(id: "Orus", name: "Orus", tagline: "Confident, technical & steady")
    ]

    static let defaultRelayHost = "100.64.0.4:8796"
    static let defaultRelayToken = "4cd31be1ce3675681348e83e6bc92d2e842d7d275edbdada"

    /// Per-vendor selected model id.
    @Published private(set) var models: [AIVendor: String]

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let visionVendor = "vision_vendor"
        static let realtimeVendor = "realtime_vendor"
        static let realtimeModel = "realtime_model"
        static let realtimeVoice = "realtime_voice"
        static func model(_ v: AIVendor) -> String { "model_\(v.rawValue)" }
        static func key(_ v: AIVendor) -> String { "apikey_\(v.rawValue)" }
    }

    private init() {
        let savedVendor = defaults.string(forKey: Keys.visionVendor).flatMap(AIVendor.init) ?? .gemini
        self.visionVendor = savedVendor
        // Live AI is Gemini Live only. Do not let a persisted legacy selection
        // silently route a wake-triggered conversation somewhere else.
        let savedRealtimeVendor: AIVendor = .gemini
        self.realtimeVendor = .gemini
        defaults.set(AIVendor.gemini.rawValue, forKey: Keys.realtimeVendor)
        var rtModel = defaults.string(forKey: Keys.realtimeModel) ?? Self.defaultRealtimeModel
        // Reset any stale/non-Gemini value (e.g. an old "gpt-realtime-2") to the default.
        if savedRealtimeVendor == .gemini, !Self.knownRealtimeModels.contains(rtModel) {
            rtModel = Self.defaultRealtimeModel
        } else if savedRealtimeVendor == .openAI, rtModel.lowercased().contains("gemini") {
            rtModel = "gpt-realtime"
        }
        self.realtimeModel = rtModel
        let savedVoice = defaults.string(forKey: Keys.realtimeVoice) ?? Self.defaultRealtimeVoice
        self.realtimeVoice = Self.availableVoices.contains(where: { $0.id == savedVoice }) ? savedVoice : Self.defaultRealtimeVoice
        var loaded: [AIVendor: String] = [:]
        for vendor in AIVendor.allCases {
            var m = defaults.string(forKey: Keys.model(vendor)) ?? vendor.defaultModel
            if vendor == .gemini && (m == "gemini-2.5-flash" || m.isEmpty) {
                m = "gemini-3.8-flash"
                defaults.set(m, forKey: Keys.model(.gemini))
            }
            loaded[vendor] = m
        }
        self.models = loaded

        // Migrate any empty or legacy AI Studio key (AIza... / AQ....) to the minimax Vertex AI Ultra relay token.
        let existingGeminiKey = KeychainStore.get(Keys.key(.gemini)) ?? ""
        if existingGeminiKey.isEmpty || existingGeminiKey.hasPrefix("AIza") || existingGeminiKey.hasPrefix("AQ.") {
            let bundled = (Bundle.main.object(forInfoDictionaryKey: "GeminiLiveKey") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let relayToken = (!bundled.isEmpty && !bundled.hasPrefix("$(")) ? bundled : Self.defaultRelayToken
            KeychainStore.set(relayToken, for: Keys.key(.gemini))
        }
    }

    // MARK: Models

    /// Model ids that only work on non-chat endpoints (Realtime/audio/etc.). If one
    /// was ever selected for vision, fall back to the vendor's default chat model so
    /// requests don't 404 with "This is not a chat model."
    private static let nonChatMarkers = ["realtime", "audio", "tts", "whisper", "embedding", "transcribe", "dall-e", "image"]

    func model(for vendor: AIVendor) -> String {
        let saved = models[vendor] ?? vendor.defaultModel
        if Self.nonChatMarkers.contains(where: saved.lowercased().contains) { return vendor.defaultModel }
        return saved
    }

    func setModel(_ model: String, for vendor: AIVendor) {
        models[vendor] = model
        defaults.set(model, forKey: Keys.model(vendor))
    }

    // MARK: API keys (Keychain)

    func apiKey(for vendor: AIVendor) -> String {
        let saved = KeychainStore.get(Keys.key(vendor)) ?? ""
        if vendor == .gemini {
            if !saved.isEmpty && !saved.hasPrefix("AIza") && !saved.hasPrefix("AQ.") {
                return saved
            }
            let bundled = (Bundle.main.object(forInfoDictionaryKey: "GeminiLiveKey") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !bundled.isEmpty && !bundled.hasPrefix("$(") {
                return bundled
            }
            return Self.defaultRelayToken
        }
        return saved
    }

    func geminiRelayHost() -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "GeminiRelayHost") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty && !raw.hasPrefix("$(") {
            return raw
        }
        return Self.defaultRelayHost
    }

    func geminiRelayWebSocketURL() -> String {
        "ws://\(geminiRelayHost())/ws/live"
    }

    func geminiRelayRESTBaseURL() -> String {
        "http://\(geminiRelayHost())/v1beta"
    }

    func setAPIKey(_ key: String, for vendor: AIVendor) {
        KeychainStore.set(key, for: Keys.key(vendor))
        objectWillChange.send()
    }

    func hasKey(for vendor: AIVendor) -> Bool {
        !apiKey(for: vendor).isEmpty
    }

    /// API key for the realtime voice provider. Falls back to the bundled Gemini
    /// Live key (from Config/Secrets.xcconfig → Info.plist) when the user hasn't
    /// entered one, so Live AI works out of the box on Gemini.
    func realtimeAPIKey() -> String {
        let saved = apiKey(for: realtimeVendor)
        if !saved.isEmpty { return saved }
        if realtimeVendor == .gemini {
            return (Bundle.main.object(forInfoDictionaryKey: "GeminiLiveKey") as? String) ?? ""
        }
        return ""
    }

    // MARK: Active provider

    /// The provider to use for vision/chat features, or nil if no key is set.
    func visionProvider() -> ChatVisionProvider? {
        let key = apiKey(for: visionVendor)
        guard !key.isEmpty else { return nil }
        return makeProvider(visionVendor, apiKey: key)
    }

    func currentModel() -> String { model(for: visionVendor) }
}
