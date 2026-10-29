import Foundation

/// Google Gemini via the Generative Language REST API.
/// Auth is the standard API-key query parameter (`?key=`), not a Bearer token.
public struct GeminiProvider: ChatVisionProvider {
    public static let defaultRelayBaseURL = "http://100.64.0.4:8796/v1beta"

    public let vendor: AIVendor = .gemini
    private let apiKey: String
    private let baseURL: String
    private let session: URLSession

    public init(
        apiKey: String,
        baseURL: String = GeminiProvider.defaultRelayBaseURL,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    public func generate(_ request: AIRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }

        let contents = request.messages.map { message -> [String: Any] in
            var parts: [[String: Any]] = []
            if !message.text.isEmpty { parts.append(["text": message.text]) }
            for image in message.images {
                parts.append(["inline_data": ["mime_type": "image/jpeg", "data": image.base64]])
            }
            return ["role": message.role == .assistant ? "model" : "user", "parts": parts]
        }

        var body: [String: Any] = ["contents": contents]
        if let system = request.system {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        var genConfig: [String: Any] = [:]
        if let maxTokens = request.maxTokens { genConfig["maxOutputTokens"] = maxTokens }
        if let temperature = request.temperature { genConfig["temperature"] = temperature }
        if !genConfig.isEmpty { body["generationConfig"] = genConfig }

        let url = URL(string: "\(baseURL)/models/\(request.model):generateContent?key=\(apiKey)")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await HTTP.send(urlRequest, session: session)
        return try Self.parseText(data)
    }

    static func parseText(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.decoding("not a JSON object")
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw AIProviderError.noContent
        }
        let text = parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw AIProviderError.noContent }
        return text
    }
}
