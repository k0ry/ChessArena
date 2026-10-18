import AVFoundation
import XCTest
@testable import ChessArenaCore

final class LocalQwenTests: XCTestCase {
    @MainActor
    func testPreparingNextSpeechDoesNotStopPlaybackAndPlaybackCallsQueue() async throws {
        let server = MiniHTTPServer()
        server.handler = { _ in .init(status: 200, body: Data(repeating: 0, count: 48_000)) }
        try server.start(); defer { server.stop() }
        let fallback = ScriptedVoice()
        let voice = makeVoice(server, fallback: fallback)
        let first = await voice.prepare("Первая", kind: .move, profile: .host)
        XCTAssertFalse(voice.isSpeaking)
        var starts: [String] = []
        let playing = Task { await voice.play(first) { starts.append("first") } }
        while starts.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let second = await voice.prepare("Вторая", kind: .taunt, profile: .persona(.burr))
        XCTAssertTrue(voice.isSpeaking, "Synthesis cannot stop the first audio player")
        let queued = Task { await voice.play(second) { starts.append("second") } }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(starts, ["first"])
        let firstSamples = await playing.value
        XCTAssertEqual(firstSamples.count, 44_100)
        let secondSamples = await queued.value
        XCTAssertEqual(secondSamples.count, 44_100)
        XCTAssertEqual(starts, ["first", "second"])
        XCTAssertTrue(fallback.spoken.isEmpty)
    }

    func testCastingDefaultsAreDistinctAndInvalidOverridesFallBack() {
        let casting = QwenVoiceCasting(entries: ["carrey": "removed-speaker", "unknown-persona": "Ryan"])
        XCTAssertTrue(casting.entries.isEmpty)
        let voices = PlayerPersona.allCases.map { casting.voice(for: $0) }
        XCTAssertEqual(Set(voices + ["Ryan"]).count, 9)
        XCTAssertTrue(voices.allSatisfy(LocalQwenConfiguration.voices.contains))
        let profiles: [VoiceProfile] = [.host] + PlayerPersona.allCases.map { .persona($0) }
        XCTAssertEqual(Set(profiles.map(\.neuralDelivery)).count, 9)
        XCTAssertTrue(profiles.allSatisfy { $0.neuralDelivery.count <= 500 })
    }

    @MainActor
    func testAllProfilesSendTheirOwnVoiceAndDirectionIncludingOverride() async throws {
        let server = MiniHTTPServer()
        var received: [[String: String]] = []
        server.handler = { request in
            received.append(try! JSONSerialization.jsonObject(with: Data(request.bodyText.utf8)) as! [String: String])
            return .init(status: 200, body: Data(repeating: 0, count: 4800))
        }
        try server.start(); defer { server.stop() }
        let fallback = ScriptedVoice()
        let voice = makeVoice(server, fallback: fallback)
        let profiles: [VoiceProfile] = [.host] + PlayerPersona.allCases.map { .persona($0) }
        for profile in profiles {
            let samples = await voice.speak("Одинаковый текст", kind: .tone, profile: profile)
            XCTAssertEqual(samples.count, 4410)
        }
        XCTAssertEqual(Set(received.compactMap { $0["voice"] }).count, 9)
        XCTAssertEqual(received.compactMap { $0["instructions"] }, profiles.map(\.neuralDelivery))
        voice.qwenCasting.setVoice("Aiden", for: .burr)
        _ = await voice.speak("Моя очередь", kind: .taunt, profile: .persona(.burr))
        XCTAssertEqual(received.last?["voice"], "Aiden")
        XCTAssertEqual(received.last?["instructions"], VoiceProfile.persona(.burr).neuralDelivery)
        XCTAssertTrue(fallback.spoken.isEmpty)
    }

    @MainActor
    func testInstalledCastSmoke() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHESSARENA_TTS_CAST_SMOKE_ROOT"] else {
            throw XCTSkip("Opt-in local model cast check")
        }
        let root = URL(fileURLWithPath: path)
        let server = LocalQwenServer(directory: root.appendingPathComponent(".local-tts"),
                                     script: root.appendingPathComponent("scripts/qwen-server.py"))
        defer { server.stop() }
        try await server.ensureRunning()
        let output = root.appendingPathComponent("output/local-tts/cast")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let profiles: [VoiceProfile] = [.host] + PlayerPersona.allCases.map { .persona($0) }
        var rows: [[String: Any]] = []
        var combined = Data()
        for (index, profile) in profiles.enumerated() {
            let speaker: String
            let role: String
            switch profile {
            case .host: speaker = "Ryan"; role = "host"
            case .persona(let persona): speaker = QwenVoiceCasting().voice(for: persona); role = persona.rawValue
            }
            let started = Date()
            let pcm = try await QwenSpeechAPI().audio(text: "Конь выходит на эф три. Теперь твой ход.",
                voice: speaker, language: .russian, instructions: profile.neuralDelivery)
            XCTAssertGreaterThan(pcm.count, 24_000)
            XCTAssertTrue(pcm.contains { $0 != 0 })
            let wav = BroadcastVoice.wav(pcm)
            let player = try AVAudioPlayer(data: wav)
            XCTAssertEqual(Double(BroadcastVoice.archiveSamples(pcm).count) / 44100, player.duration, accuracy: 0.001)
            let filename = String(format: "%02d-%@-%@.wav", index + 1, role, speaker)
            try wav.write(to: output.appendingPathComponent(filename))
            let seconds = Date().timeIntervalSince(started)
            rows.append(["role": role, "voice": speaker, "file": filename, "duration": player.duration,
                         "synthesisSeconds": seconds, "startSeconds": Double(combined.count) / 48000])
            combined.append(pcm)
            combined.append(Data(repeating: 0, count: 24000))
            print("QWEN CAST: \(role) / \(speaker): synthesis=\(seconds)s audio=\(player.duration)s")
        }
        try BroadcastVoice.wav(combined).write(to: output.appendingPathComponent("qwen-cast-ru.wav"))
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("manifest.json"))
    }

    /// Explicit opt-in: exercises the installed model and process lifecycle, without cloud services.
    @MainActor
    func testInstalledModelSmoke() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHESSARENA_TTS_SMOKE_ROOT"] else {
            throw XCTSkip("Set CHESSARENA_TTS_SMOKE_ROOT to test the installed MLX model.")
        }
        let root = URL(fileURLWithPath: path)
        let server = LocalQwenServer(directory: root.appendingPathComponent(".local-tts"),
                                     script: root.appendingPathComponent("scripts/qwen-server.py"))
        defer { server.stop() }
        try await server.ensureRunning()
        let started = Date()
        let pcm = try await QwenSpeechAPI().audio(
            text: "Добро пожаловать на шахматную арену. Конь выходит на эф три. Белые начинают борьбу за центр.",
            voice: "Ryan", language: .russian, instructions: "Speak clearly, confidently, like a chess commentator.")
        XCTAssertGreaterThan(pcm.count, 48_000)
        XCTAssertTrue(pcm.contains { $0 != 0 })
        let wav = BroadcastVoice.wav(pcm)
        let player = try AVAudioPlayer(data: wav)
        let samples = BroadcastVoice.archiveSamples(pcm)
        XCTAssertEqual(Double(samples.count) / 44100, player.duration, accuracy: 0.001)
        let output = root.appendingPathComponent("output/local-tts")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try wav.write(to: output.appendingPathComponent("qwen-ryan-ru.wav"))
        print("QWEN LIVE: synthesis=\(Date().timeIntervalSince(started))s audio=\(player.duration)s archiveSamples=\(samples.count)")
    }

    @MainActor
    func testLocalRequestUsesRussianAndQwenVoiceWithoutOpenAISecret() async throws {
        let server = MiniHTTPServer()
        server.handler = { request in
            XCTAssertEqual(request.path, "/v1/audio/speech")
            XCTAssertNil(request.headers["authorization"])
            XCTAssertFalse(request.bodyText.contains("private-openai-key"))
            let body = try! JSONSerialization.jsonObject(with: Data(request.bodyText.utf8)) as! [String: String]
            XCTAssertEqual(body["model"], LocalQwenConfiguration.model)
            XCTAssertEqual(body["language"], "Russian")
            XCTAssertEqual(body["voice"], "Ryan")
            XCTAssertEqual(body["response_format"], "pcm")
            XCTAssertEqual(body["input"], "Конь на эф три.")
            return .init(status: 200, body: Data(repeating: 0, count: 4800))
        }
        try server.start(); defer { server.stop() }
        let fallback = ScriptedVoice()
        let voice = makeVoice(server, fallback: fallback)
        voice.apiKey = "private-openai-key"
        let samples = await voice.speak("Конь на эф три.", kind: .tone, profile: .host)
        XCTAssertEqual(samples.count, 4410)
        XCTAssertTrue(fallback.spoken.isEmpty)
        XCTAssertEqual(voice.status, "Qwen · локально · Ryan")
        XCTAssertTrue(NetworkLog.shared.entries.contains { $0.operation == .localSpeech && $0.httpStatus == 200 })
    }

    @MainActor
    func testLocalFailureUsesSystemVoiceAndDoesNotEchoServerBody() async throws {
        let server = MiniHTTPServer()
        server.handler = { _ in .init(status: 503, body: Data(#"{"error":"sensitive-server-output"}"#.utf8)) }
        try server.start(); defer { server.stop() }
        let fallback = ScriptedVoice()
        let voice = makeVoice(server, fallback: fallback)
        _ = await voice.speak("Проверка", kind: .tone, profile: .host)
        XCTAssertEqual(fallback.spoken.count, 1)
        XCTAssertTrue(voice.status.contains("HTTP 503"))
        XCTAssertFalse(voice.status.contains("sensitive-server-output"))
        XCTAssertFalse(NetworkLog.shared.entries.first?.text.contains("sensitive-server-output") == true)
    }

    @MainActor
    func testInvalidPCMIsRejected() async throws {
        let server = MiniHTTPServer()
        server.handler = { _ in .init(status: 200, body: Data([1, 2, 3])) }
        try server.start(); defer { server.stop() }
        let fallback = ScriptedVoice()
        let voice = makeVoice(server, fallback: fallback)
        _ = await voice.speak("Проверка", kind: .tone, profile: .host)
        XCTAssertEqual(fallback.spoken.count, 1)
        XCTAssertTrue(voice.status.contains("некорректный PCM"))
    }

    @MainActor
    func testCancellationDuringRequestDoesNotPlayFallback() async throws {
        let received = expectation(description: "Request started")
        let server = MiniHTTPServer()
        server.handler = { _ in
            received.fulfill()
            Thread.sleep(forTimeInterval: 0.2)
            return .init(status: 200, body: Data(repeating: 0, count: 4800))
        }
        try server.start(); defer { server.stop() }
        let fallback = ScriptedVoice()
        let voice = makeVoice(server, fallback: fallback)
        let task = Task { await voice.speak("Проверка", kind: .tone, profile: .host) }
        await fulfillment(of: [received], timeout: 2)
        voice.stop()
        let samples = await task.value
        XCTAssertTrue(samples.isEmpty)
        XCTAssertTrue(fallback.spoken.isEmpty)
        XCTAssertFalse(voice.isSpeaking)
    }

    func testLocalSelectionAndVoicePersist() throws {
        var state = SavedSession(game: nil, series: MatchSeries(), white: .init(provider: .grok), black: .init(provider: .grok), hostModel: "test", language: .russian, useChatGPTLogin: true, camera: .init(manual: false, yaw: 0, pitch: 0, distance: 12))
        XCTAssertNil(state.qwenVoice)
        XCTAssertNil(state.qwenPersonaVoices)
        let legacy = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(state))
        XCTAssertNil(legacy.qwenPersonaVoices)
        XCTAssertEqual(QwenVoiceCasting(entries: legacy.qwenPersonaVoices ?? [:]).voice(for: .burr), "Vivian")
        state.voiceProvider = .localQwen
        state.qwenVoice = "Aiden"
        state.qwenPersonaVoices = ["burr": "Eric", "carlin": "Uncle_Fu"]
        let restored = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.voiceProvider, .localQwen)
        XCTAssertEqual(restored.qwenVoice, "Aiden")
        let casting = QwenVoiceCasting(entries: restored.qwenPersonaVoices ?? [:])
        XCTAssertEqual(casting.voice(for: .burr), "Eric")
        XCTAssertEqual(casting.voice(for: .carlin), "Uncle_Fu")
    }

    @MainActor
    private func makeVoice(_ server: MiniHTTPServer, fallback: ScriptedVoice) -> BroadcastVoice {
        let localAPI = QwenSpeechAPI(endpoint: URL(string: "http://127.0.0.1:\(server.port)/v1/audio/speech")!)
        let voice = BroadcastVoice(fallback: fallback, api: SpeechAPI(), localAPI: localAPI)
        voice.provider = .localQwen
        voice.language = .russian
        return voice
    }
}
