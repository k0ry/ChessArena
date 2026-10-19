import Foundation
import XCTest
@testable import ChessArenaCore

@MainActor
final class RequestRetryIntegrationTests: XCTestCase {
    func testRealCLITimeoutAutomaticallyRetriesSamePositionWithoutScoring() async throws {
        let fixture = try CLIRetryFixture(mode: .timeoutOnce)
        defer { fixture.cleanup() }
        let engine = fixture.engine
        engine.requestTimeout = 5
        try await engine.start(at: 0)
        try await waitUntil { engine.paused }
        XCTAssertEqual(engine.picture.requestStatus?.mode, .retryScheduled)
        XCTAssertEqual(engine.picture.requestStatus?.secondsLeft, 3)
        XCTAssertEqual(engine.picture.requestStatus?.attempt, 2)
        XCTAssertEqual(engine.referee.position, .standard())
        XCTAssertNil(engine.referee.end)
        XCTAssertEqual(engine.finalCards, 0)
        XCTAssertEqual(fixture.series.score.games, 0)
        XCTAssertTrue(engine.archive.pgnText().contains("[Result \"*\"]"))
        // Runtime invokes advance even while paused. No resume/repeat or user input.
        await engine.advance(to: 2)
        XCTAssertEqual(engine.moveRequestCount, 1)
        XCTAssertEqual(engine.picture.requestStatus?.secondsLeft, 1)
        await engine.advance(to: 3)
        try await fixture.waitForAcceptedMove()
        XCTAssertEqual(engine.referee.accepted.map(\.move.uci), ["e2e4"])
        XCTAssertEqual(fixture.series.score.games, 0)
        XCTAssertEqual(engine.finalCards, 0)
        engine.stop()
        try await engine.closeArchive()
        let events = try fixture.events()
        let firstTurn = events.filter { $0.logicalTurnID == "\(engine.archive.roundID.uuidString):0" }
        XCTAssertEqual(firstTurn.filter { $0.event == "request" }.count, 2)
        XCTAssertEqual(Set(firstTurn.compactMap(\.requestID)).count, 2)
        XCTAssertEqual(firstTurn.first { $0.event == "retry" }?.retryDecision, "scheduled")
        XCTAssertNotNil(firstTurn.first { $0.event == "retry" }?.timeoutSource)
        XCTAssertEqual(firstTurn.first { $0.event == "request" }?.timeoutSeconds, 5)
        XCTAssertEqual(firstTurn.filter { $0.event == "response_received" }.count, 1)
        XCTAssertEqual(firstTurn.filter { $0.event == "accepted" }.count, 1)
        XCTAssertFalse(events.contains { $0.event == "finished" })
    }

    func testResponseAfter130SecondsIsAcceptedThroughGeminiRoute() async throws {
        guard ProcessInfo.processInfo.environment["CHESSARENA_LONG_CLI_TEST"] == "1" else {
            throw XCTSkip("Opt-in 130 second local CLI test; no provider calls")
        }
        let fixture = try CLIRetryFixture(mode: .slow)
        defer { fixture.cleanup() }
        let started = RequestTiming.monotonicNow()
        try await fixture.engine.start(at: 0)
        while fixture.engine.referee.accepted.isEmpty, RequestTiming.monotonicNow() - started < 150 {
            await fixture.engine.advance(to: RequestTiming.monotonicNow() - started)
            fixture.answerHost()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(fixture.engine.referee.accepted.map(\.move.uci), ["e2e4"])
        XCTAssertGreaterThanOrEqual(RequestTiming.monotonicNow() - started, 130)
        XCTAssertEqual(fixture.series.score.games, 0)
        fixture.engine.stop()
        try await fixture.engine.closeArchive()
        let budget = try String(contentsOf: fixture.directory.appendingPathComponent("budget"), encoding: .utf8)
        XCTAssertEqual(budget.trimmingCharacters(in: .whitespacesAndNewlines), "600s")
        let events = try fixture.events()
        XCTAssertFalse(events.contains { $0.event == "retry" || $0.event == "paused" })
        XCTAssertTrue(events.contains { $0.event == "response_received" && ($0.duration ?? 0) >= 130 })
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected request state was not reached")
    }
}

@MainActor
private final class CLIRetryFixture {
    enum Mode { case timeoutOnce, slow }
    let directory: URL
    let engine: MatchEngine
    let host = ScriptedChat()
    var series = MatchSeries()

    init(mode: Mode) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("retry-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-agy")
        let delay = mode == .slow ? "sleep 130" : "if [ ! -f '\(directory.path)/attempt' ]; then touch '\(directory.path)/attempt'; sleep 20; fi"
        let content = """
        #!/bin/sh
        if [ "$1" = '--version' ]; then printf '1.3.3\\n'; exit; fi
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--print-timeout' ]; then shift; printf '%s' "$1" > '\(directory.path)/budget'; break; fi
          shift
        done
        \(delay)
        printf '%s' '{"status":"SUCCESS","num_turns":1,"structured_output":{"move":"e2e4","taunt":""}}'
        """
        try content.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let transport = ArenaChatTransport(connection: nil, api: host, gemini: GeminiCLI(binary: script.path, home: directory))
        let white = Seat(name: "Gemini", baseURL: URL(string: "local-cli://antigravity")!, model: "gemini-fixture", apiKey: "", side: .white, route: .geminiCLI)
        let round = series.start()
        let archive = MatchArchive(directory: directory.appendingPathComponent("archive"), whiteName: "Gemini", blackName: "Fixture")
        engine = MatchEngine(scene: BoardScene(), voice: ScriptedVoice(), transport: transport, archive: archive,
            white: white, black: .defaultBlack(apiKey: ""), host: .defaultWhite(apiKey: ""))
        engine.onGameEnded = { [weak self] end in
            guard let self else { return }
            _ = self.series.complete(round: round, result: end, position: self.engine.referee.position, now: 0)
        }
    }
    func answerHost() {
        host.fulfill(where: { $0.system.contains("already on the board") }, body: "Move ready.")
    }
    func waitForAcceptedMove() async throws {
        for _ in 0..<1500 {
            answerHost()
            if !engine.referee.accepted.isEmpty { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("No accepted move after retry")
    }
    func events() throws -> [MatchDiagnostic] {
        try String(contentsOf: engine.archive.diagnosticsURL, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(MatchDiagnostic.self, from: Data($0.utf8))
        }
    }
    func cleanup() {
        engine.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}
