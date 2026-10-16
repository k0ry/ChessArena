import XCTest
@testable import ChessArenaCore

@MainActor
final class GameMemoryTests: XCTestCase {
    func testMemoryIsBoundedSanitizedAndIsolatedByModelColorAndProvider() throws {
        let white = Seat.defaultWhite(apiKey: "private-test-secret")
        var black = white; black.side = .black
        var otherModel = white; otherModel.model = "other"
        var otherProvider = white; otherProvider.baseURL = ModelCatalog.openAIAPI
        var memory = GameMemory()
        memory.remember("Remember private-test-secret", for: white)
        XCTAssertEqual(memory.advice(for: white), "Remember [REDACTED]")
        XCTAssertNil(memory.advice(for: black))
        XCTAssertNil(memory.advice(for: otherModel))
        XCTAssertNil(memory.advice(for: otherProvider))
        memory.remember("   \n ", for: white)
        XCTAssertEqual(memory.advice(for: white), "Remember [REDACTED]")
        memory.remember(String(repeating: "x", count: 5_000), for: black)
        XCTAssertEqual(memory.advice(for: black)?.count, 4_000)
        let restored = try JSONDecoder().decode(GameMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(restored, memory)
    }

    func testMemorySurvivesSessionRestartAndNewSeriesWithoutAGame() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(url: folder.appendingPathComponent("session.json"))
        let white = Seat.defaultWhite(apiKey: "")
        var memory = GameMemory()
        memory.remember("Protect the king before attacking.", for: white)
        var state = SavedSession(game: nil, series: MatchSeries(), white: .init(provider: .grok),
                                 black: .init(provider: .chatGPT), hostModel: "host", language: .russian,
                                 useChatGPTLogin: true, camera: .init(manual: false, yaw: 0, pitch: 0, distance: 12),
                                 gameMemory: memory)
        _ = state.series.startNewSeries()
        state.series.stop()
        try store.save(state)
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.gameMemory?.advice(for: white), "Protect the king before attacking.")
        XCTAssertEqual(restored.series.score.games, 0)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        legacy.removeValue(forKey: "gameMemory")
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.url)
        XCTAssertNil(try store.load()?.gameMemory, "Older sessions still load without learning data")
    }
}
