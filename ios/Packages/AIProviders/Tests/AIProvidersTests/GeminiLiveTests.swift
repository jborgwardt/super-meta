import XCTest
@testable import AIProviders

/// Live integration tests against the Gemini API.
/// Skipped automatically unless `GEMINI_API_KEY` is set in the environment, so
/// normal offline builds/CI stay green.
final class GeminiLiveTests: XCTestCase {

    private var apiKey: String {
        get throws {
            guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else {
                throw XCTSkip("GEMINI_API_KEY not set — skipping live Gemini test")
            }
            return key
        }
    }

    func testTextGeneration() async throws {
        let provider = GeminiProvider(apiKey: try apiKey)
        let request = AIRequest(
            model: AIVendor.gemini.defaultModel,
            prompt: "Say hello in five words."
        )
        // Validates the transport: a successful, non-empty completion.
        let result = try await provider.generate(request)
        XCTAssertFalse(result.isEmpty, "Empty response from Gemini")
    }

    func testVisionGeneration() async throws {
        let provider = GeminiProvider(apiKey: try apiKey)
        // A minimal valid 32x32 RGB JPEG — enough to exercise the inline_data multimodal path.
        let jpegBase64 = "/9j/4AAQSkZJRgABAgAAAQABAAD//gAPTGF2YzYzLjEuMTAyAP/bAEMACAQEBAQEBQUFBQUFBgYGBgYGBgYGBgYGBgcHBwgICAcHBwYGBwcICAgICQkJCAgICAkJCgoKDAwLCw4ODhERFP/EAE0AAQEAAAAAAAAAAAAAAAAAAAAHAQEBAQAAAAAAAAAAAAAAAAAABQcQAQAAAAAAAAAAAAAAAAAAAAARAQAAAAAAAAAAAAAAAAAAAAD/wAARCAAgACADASIAAhEAAxEA/9oADAMBAAIRAxEAPwCOAN/SgAAAAAH/2Q=="
        let image = AIImage(jpegData: Data(base64Encoded: jpegBase64)!)
        let request = AIRequest(
            model: AIVendor.gemini.defaultModel,
            prompt: "Briefly describe this image in one sentence.",
            images: [image]
        )
        let result = try await provider.generate(request)
        XCTAssertFalse(result.isEmpty, "Vision path returned empty text")
        print("VISION_RESULT: \(result)")
    }
}

/// Offline unit tests that always run (no network).
final class AIProviderUnitTests: XCTestCase {

    func testGeminiResponseParsing() throws {
        let json = """
        {"candidates":[{"content":{"parts":[{"text":"hello "},{"text":"world"}]}}]}
        """.data(using: .utf8)!
        XCTAssertEqual(try GeminiProvider.parseText(json), "hello world")
    }

    func testVendorDefaults() {
        XCTAssertEqual(AIVendor.allCases.count, 4)
        XCTAssertEqual(AIVendor.gemini.defaultModel, "gemini-2.5-flash")
        XCTAssertEqual(AIVendor.openAI.displayName, "OpenAI")
    }

    func testFactoryReturnsCorrectVendor() {
        XCTAssertEqual(makeProvider(.claude, apiKey: "x").vendor, .claude)
        XCTAssertEqual(makeProvider(.openRouter, apiKey: "x").vendor, .openRouter)
    }
}
