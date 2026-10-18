import AVFoundation
import XCTest
@testable import ChessArenaCore

@MainActor
final class SynchronizedSpeechLiveTests: XCTestCase {
    /// Real local synthesis, playback, SceneKit animation and timestamped archive; no cloud calls.
    func testInstalledQwenTwoMovePresentation() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHESSARENA_TTS_SYNC_SMOKE_ROOT"] else {
            throw XCTSkip("Opt-in Qwen synchronized match check")
        }
        let root = URL(fileURLWithPath: path)
        let output = root.appendingPathComponent("output/local-tts/synchronized-" + UUID().uuidString)
        let server = LocalQwenServer(directory: root.appendingPathComponent(".local-tts"), script: root.appendingPathComponent("scripts/qwen-server.py"))
        let voice = BroadcastVoice(fallback: SystemVoice(), api: SpeechAPI(), localServer: server)
        voice.provider = .localQwen; voice.language = .russian
        defer { voice.shutdown() }
        let chat = ScriptedChat()
        var white = Seat.defaultWhite(apiKey: ""); white.persona = .pryor
        var black = Seat.defaultBlack(apiKey: ""); black.persona = .carrey
        let archive = MatchArchive(directory: output, whiteName: "White", blackName: "Black")
        let engine = MatchEngine(scene: BoardScene(), voice: voice, transport: chat, archive: archive,
                                 white: white, black: black, host: white)
        engine.language = .russian; engine.animationDuration = 1.2
        engine.restore(engine.checkpoint) // Skip the long lineup; exercise two complete turns.
        try await engine.start(at: 0)
        let start = Date()
        let ticker = Task {
            while !Task.isCancelled {
                await engine.advance(to: Date().timeIntervalSince(start))
                if let frame = engine.scene.copyFrame() { engine.appendFrame(frame) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { ticker.cancel(); engine.stop() }
        try await wait { chat.calls.contains { $0.system.contains("You are White") } }
        chat.fulfill(where: { $0.system.contains("You are White") }, body: #"{"move":"e2e4","taunt":"Теперь твой ход!"}"#)
        try await wait { chat.calls.contains { $0.system.contains("already on the board") } }
        let commentary = "Белые двигают пешку на е четыре и занимают центр. Это начало открытой борьбы: сопернику предстоит решить, ответить ли симметрично или выбрать другой план. Пока фигуры стоят на исходных местах, но первый шаг уже задаёт характер всей партии. Посмотрим, как ответят чёрные."
        chat.fulfill(where: { $0.system.contains("already on the board") }, body: commentary)
        XCTAssertEqual(engine.boardVersion, 0)
        try await wait { chat.calls.contains { $0.system.contains("You are Black") } }
        XCTAssertTrue(voice.isSpeaking)
        let firstStart = engine.clock
        chat.fulfill(where: { $0.system.contains("You are Black") }, body: #"{"move":"e7e5","taunt":"Центр придётся разделить!"}"#)
        try await wait { chat.calls.filter { $0.system.contains("already on the board") }.count == 2 }
        XCTAssertEqual(engine.boardVersion, 1)
        chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Чёрные отвечают пешкой на е пять. Обе стороны заняли центр, теперь пора развивать фигуры.")
        try await wait { engine.spokenTaunts.count == 2 && engine.speech.filter { $0.kind == .move }.count == 2 }
        XCTAssertEqual(engine.speech.filter { $0.kind == .move }.count, 2)
        XCTAssertEqual(engine.speech.first { $0.kind == .move }?.text, commentary)
        XCTAssertEqual(engine.spokenTaunts.map(\.boardVersion), [1, 2])
        XCTAssertFalse(voice.status.contains("системный"), voice.status)
        XCTAssertGreaterThan(engine.speech.last!.clock, firstStart)
        engine.stop(); ticker.cancel()
        try await engine.closeArchive()
        let asset = AVURLAsset(url: archive.videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videoTracks.first)
        let audio = try XCTUnwrap(audioTracks.first)
        let videoRange = try await video.load(.timeRange)
        let audioRange = try await audio.load(.timeRange)
        XCTAssertEqual(videoRange.duration.seconds, audioRange.duration.seconds, accuracy: 0.5)
        let reader = try AVAssetReader(asset: asset)
        let outputFrames = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(outputFrames); XCTAssertTrue(reader.startReading())
        var timestamps: [Double] = []
        while let sample = outputFrames.copyNextSampleBuffer() {
            timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        timestamps.sort()
        XCTAssertEqual(reader.status, .completed)
        let longestGap = zip(timestamps, timestamps.dropFirst()).map { $1 - $0 }.max() ?? .infinity
        XCTAssertLessThan(longestGap, 0.5, "Audio backpressure must not freeze video during synthesis or speech")
        let events = engine.speech + engine.spokenTaunts
        let data = events.sorted { $0.clock < $1.clock }.map {
            ["text": $0.text, "kind": $0.kind.rawValue, "boardVersion": $0.boardVersion, "startSeconds": $0.clock] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("timing.json"))
        print("QWEN SYNC ARCHIVE: \(archive.videoURL.path)")
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(180)
        while !predicate() {
            guard Date() < deadline else { throw NSError(domain: "QwenSyncTestTimeout", code: 1) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
