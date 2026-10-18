import AVFoundation
import XCTest
@testable import ChessArenaCore

final class SpeechAPITests: XCTestCase {
    func testDiagnosticsSeparateCredentialsAndNeverEchoProviderMessage() {
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/audio/speech")!, statusCode: 401, httpVersion: nil, headerFields: ["x-request-id": "req_12345678"])!
        let body = Data(#"{"error":{"code":"invalid_api_key","message":"secret-token"}}"#.utf8)
        let subscription = SpeechFailure.http(response, data: body, subscription: true, secret: "secret-token").message
        let api = SpeechFailure.http(response, data: body, subscription: false, secret: "secret-token").message
        XCTAssertTrue(subscription.contains("Токен входа ChatGPT"))
        XCTAssertTrue(api.contains("API-ключ"))
        XCTAssertTrue(api.contains("invalid_api_key"))
        XCTAssertTrue(api.contains("req_12345678"))
        XCTAssertFalse(api.contains("secret-token"))
        let malicious = Data(#"{"error":{"code":"secret-token","message":"secret-token"}}"#.utf8)
        XCTAssertFalse(SpeechFailure.http(response, data: malicious, subscription: false, secret: "secret-token").message.contains("secret-token"))
    }

    @MainActor
    func testPCMPlaybackContainerAndArchiveDuration() throws {
        let pcm = Data(repeating: 0, count: 48_000)
        let player = try AVAudioPlayer(data: BroadcastVoice.wav(pcm))
        XCTAssertEqual(player.duration, 1, accuracy: 0.001)
        XCTAssertEqual(BroadcastVoice.archiveSamples(pcm).count, 44_100)
    }

    @MainActor
    func testAPIRequestAndFallbackLog() async throws {
        let server = MiniHTTPServer()
        server.handler = { request in
            XCTAssertEqual(request.headers["authorization"], "Bearer speech-only")
            XCTAssertTrue(request.bodyText.contains("gpt-4o-mini-tts"))
            return .init(status: 401, body: Data(#"{"error":{"code":"invalid_api_key","message":"speech-only"}}"#.utf8))
        }
        try server.start(); defer { server.stop() }
        let fallback = ScriptedVoice()
        let voice = BroadcastVoice(fallback: fallback, api: SpeechAPI(endpoint: URL(string: "http://127.0.0.1:\(server.port)/v1/audio/speech")!))
        voice.provider = .openAIKey; voice.apiKey = "speech-only"
        let samples = await voice.speak("Проверка", kind: .tone, profile: .host)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertEqual(fallback.spoken.count, 1)
        XCTAssertTrue(voice.status.contains("HTTP 401"))
        XCTAssertFalse(voice.status.contains("speech-only"))
        let entry = try XCTUnwrap(NetworkLog.shared.entries.first { $0.operation == .speechAPI })
        XCTAssertTrue(entry.error?.contains("invalid_api_key") == true)
        XCTAssertFalse(entry.text.contains("speech-only"))
    }

    @MainActor
    func testSuccessReturnsResampledAudioAndCancellationDoesNotFallback() async throws {
        let server = MiniHTTPServer()
        server.handler = { _ in .init(status: 200, body: Data(repeating: 0, count: 4800)) }
        try server.start(); defer { server.stop() }
        let fallback = ScriptedVoice()
        let voice = BroadcastVoice(fallback: fallback, api: SpeechAPI(endpoint: URL(string: "http://127.0.0.1:\(server.port)/v1/audio/speech")!))
        voice.provider = .openAIKey; voice.apiKey = "fixture-key"
        let samples = await voice.speak("Test", kind: .tone, profile: .host)
        XCTAssertEqual(samples.count, 4410)
        XCTAssertTrue(fallback.spoken.isEmpty)
        let task = Task { await voice.speak("Cancelled", kind: .tone, profile: .host) }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled.isEmpty)
        XCTAssertTrue(fallback.spoken.isEmpty)
    }

    func testVoiceSettingsRoundTripAndLegacyDefault() throws {
        var state = SavedSession(game: nil, series: MatchSeries(), white: .init(provider: .grok), black: .init(provider: .grok), hostModel: "test", language: .russian, useChatGPTLogin: true, camera: .init(manual: false, yaw: 0, pitch: 0, distance: 12))
        let legacy = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(legacy.voiceProvider ?? .system, .system)
        state.voiceProvider = .openAIKey; state.openAIVoice = "cedar"
        let restored = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.voiceProvider, .openAIKey)
        XCTAssertEqual(restored.openAIVoice, "cedar")
    }

    @MainActor
    func testSystemSelectionDoesNotSendAPIRequest() async {
        let fallback = ScriptedVoice()
        let voice = BroadcastVoice(fallback: fallback, api: SpeechAPI())
        _ = await voice.speak("Проверка", kind: .tone, profile: .host)
        XCTAssertEqual(fallback.spoken.count, 1)
        XCTAssertEqual(voice.status, "Системная озвучка")
    }
}
