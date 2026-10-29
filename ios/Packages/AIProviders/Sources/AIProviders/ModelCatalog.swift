import Foundation

public struct AIModelInfo: Identifiable, Sendable, Equatable, Comparable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static func < (lhs: AIModelInfo, rhs: AIModelInfo) -> Bool { lhs.id < rhs.id }
}

/// Orders models so flagship / newest families surface first, then alphabetically
/// (descending within a tier so higher versions lead). `priority` is an ordered
/// list of lowercase substrings, best first.
func prioritized(_ models: [AIModelInfo], _ priority: [String]) -> [AIModelInfo] {
    func rank(_ id: String) -> Int {
        let lower = id.lowercased()
        for (index, keyword) in priority.enumerated() where lower.contains(keyword) { return index }
        return priority.count
    }
    return models.sorted { a, b in
        let ra = rank(a.id), rb = rank(b.id)
        return ra == rb ? a.id > b.id : ra < rb
    }
}

/// Fetches the list of models a provider exposes for the given API key.
public func listModels(_ vendor: AIVendor, apiKey: String, session: URLSession = .shared) async throws -> [AIModelInfo] {
    guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }
    switch vendor {
    case .gemini:     return try await listGeminiModels(apiKey: apiKey, session: session)
    case .openAI:     return try await listOpenAIModels(apiKey: apiKey, session: session)
    case .claude:     return try await listClaudeModels(apiKey: apiKey, session: session)
    case .openRouter: return try await listOpenRouterModels(apiKey: apiKey, session: session)
    }
}

private func listGeminiModels(apiKey: String, session: URLSession) async throws -> [AIModelInfo] {
    let url = URL(string: "\(GeminiProvider.defaultRelayBaseURL)/models?key=\(apiKey)&pageSize=200")!
    var req = URLRequest(url: url)
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let data = try await HTTP.send(req, session: session)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = json["models"] as? [[String: Any]] else { return [] }
    let parsed = models.compactMap { entry -> AIModelInfo? in
        guard let fullName = entry["name"] as? String else { return nil }
        let methods = entry["supportedGenerationMethods"] as? [String] ?? []
        guard methods.contains("generateContent") else { return nil }
        let id = fullName.replacingOccurrences(of: "models/", with: "")
        let display = entry["displayName"] as? String ?? id
        return AIModelInfo(id: id, name: display)
    }
    return prioritized(parsed, ["gemini-4", "gemini-3.8", "gemini-3", "gemini-2.5", "gemini-2.0", "gemini-1.5", "gemini"])
}

private func listOpenAIModels(apiKey: String, session: URLSession) async throws -> [AIModelInfo] {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let data = try await HTTP.send(request, session: session)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = json["data"] as? [[String: Any]] else { return [] }
    // Vision/chat picker: exclude non-chat model families. `realtime` and `audio`
    // models only work on the Realtime API, not v1/chat/completions — offering them
    // here produces "This is not a chat model" 404s.
    let excluded = ["whisper", "tts", "embedding", "dall-e", "moderation", "audio",
                    "image", "transcribe", "search", "babbage", "davinci", "realtime", "codex"]
    let parsed = models.compactMap { entry -> AIModelInfo? in
        guard let id = entry["id"] as? String else { return nil }
        if excluded.contains(where: id.contains) { return nil }
        return AIModelInfo(id: id, name: id)
    }
    // Lead with proven multimodal chat models so the first-listed option always works.
    return prioritized(parsed, ["gpt-4o", "gpt-4.1", "gpt-5", "o4", "o3", "gpt-4", "o1"])
}

private func listClaudeModels(apiKey: String, session: URLSession) async throws -> [AIModelInfo] {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    let data = try await HTTP.send(request, session: session)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = json["data"] as? [[String: Any]] else { return [] }
    let parsed = models.compactMap { entry -> AIModelInfo? in
        guard let id = entry["id"] as? String else { return nil }
        return AIModelInfo(id: id, name: entry["display_name"] as? String ?? id)
    }
    return prioritized(parsed, ["opus-4", "sonnet-4", "claude-4", "3-7-sonnet", "3-7", "3-5-sonnet", "3-5", "claude-3"])
}

private func listOpenRouterModels(apiKey: String, session: URLSession) async throws -> [AIModelInfo] {
    var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let data = try await HTTP.send(request, session: session)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = json["data"] as? [[String: Any]] else { return [] }
    let parsed = models.compactMap { entry -> AIModelInfo? in
        guard let id = entry["id"] as? String else { return nil }
        return AIModelInfo(id: id, name: entry["name"] as? String ?? id)
    }
    return prioritized(parsed, ["gpt-5", "claude-opus-4", "gemini-3", "gpt-realtime", "claude-sonnet-4", "gemini-2.5", "llama-4", "gpt-4o", "claude-3"])
}
