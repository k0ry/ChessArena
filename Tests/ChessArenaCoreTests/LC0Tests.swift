import Darwin
import Foundation
import XCTest
@testable import ChessArenaCore

final class LC0Tests: XCTestCase {
    func testConfigurationRoutingAndSavedSelection() throws {
        let player = PlayerConfiguration(provider: .lc0)
        let seat = player.seat(side: .black, keys: ProviderKeys(grok: "secret", chatGPT: "secret", anthropic: "secret", deepseek: "secret"))
        XCTAssertEqual(seat.route, .lc0)
        XCTAssertEqual(seat.completionsURL, LC0Transport.localURL)
        XCTAssertEqual(seat.apiKey, "")
        XCTAssertFalse(player.provider.supportsHost)
        XCTAssertEqual(try JSONDecoder().decode(PlayerConfiguration.self, from: JSONEncoder().encode(player)), player)
        XCTAssertTrue(ChatError.lc0(.invalidMove).pausesWithoutRetry)
    }

    func testPositionHistoryAndLegacyCheckpoint() throws {
        var referee = Referee()
        _ = referee.submit(rawMove: "e2e4", taunt: "")
        _ = referee.submit(rawMove: "e7e5", taunt: "")
        let position = LC0Position(referee: referee)
        XCTAssertEqual(position.initialFEN, Position.standard().fen)
        XCTAssertEqual(position.moves, ["e2e4", "e7e5"])
        try position.validate()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(referee)) as? [String: Any])
        json.removeValue(forKey: "initialFEN")
        let legacy = try JSONDecoder().decode(Referee.self, from: JSONSerialization.data(withJSONObject: json))
        let recovered = LC0Position(referee: legacy)
        XCTAssertEqual(recovered.initialFEN, referee.accepted[0].fenAfter)
        XCTAssertEqual(recovered.moves, ["e7e5"])
        try recovered.validate()
    }

    func testUCIHandshakePositionAndRoutingWithoutHTTP() async throws {
        let fixture = try engineFixture("""
        while IFS= read -r line; do
          printf '%s\n' "$line" >> transcript
          case "$line" in
            uci) printf 'id name fixture\nuci'; printf 'ok\n' ;;
            isready) echo readyok ;;
            'go movetime 1000') echo 'info depth 3 nodes 42'; echo 'bestmove e2e4 ponder e7e5' ;;
            quit) cp transcript '\(NSTemporaryDirectory())chessarena-lc0-transcript'; exit 0 ;;
          esac
        done
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let lc0 = LC0Transport(settings: LC0Settings(binary: fixture.path, moveSeconds: 1), timeout: 2)
        let transport = ArenaChatTransport(connection: nil, api: NoLC0HTTP(), lc0: lc0)
        var call = callFor(Referee()); call.apiKey = "DO_NOT_SEND"; call.user = "DO_NOT_SEND"; call.selfNotes = "DO_NOT_SEND"
        let text = try await transport.complete(call)
        XCTAssertEqual(ChatParser.moveIntent(from: text)?.move, "e2e4")
        XCTAssertEqual(ChatParser.moveIntent(from: text)?.taunt, "")
        let transcriptURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chessarena-lc0-transcript")
        defer { try? FileManager.default.removeItem(at: transcriptURL) }
        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertEqual(transcript, "uci\nucinewgame\nisready\nposition fen \(Position.standard().fen)\ngo movetime 1000\nquit\n")
        XCTAssertFalse(transcript.contains("DO_NOT_SEND"))
    }

    func testInvalidMoveAndPrematureExitPause() async throws {
        for (body, expected) in [
            ("while read line; do case \"$line\" in uci) echo uciok;; isready) echo readyok;; go*) echo 'bestmove e2e5';; esac; done", LC0Error.invalidMove),
            ("echo uciok; exit 0", LC0Error.protocolError),
            ("exit 3", LC0Error.execution)
        ] {
            let binary = try engineFixture(body)
            defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
            do {
                _ = try await LC0Transport(settings: .init(binary: binary.path), timeout: 2).complete(callFor(Referee()))
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error as? ChatError, .lc0(expected)) }
        }
    }

    func testTimeoutAndCancellationTerminateProcessGroup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let binary = try engineFixture("echo $$ > '\(pidFile.path)'\nsleep 60")
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let transport = LC0Transport(settings: .init(binary: binary.path), timeout: 2)
        do { _ = try await transport.complete(callFor(Referee())); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ChatError, .lc0(.timeout)) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
        try FileManager.default.removeItem(at: pidFile)
        let cancellable = LC0Transport(settings: .init(binary: binary.path), timeout: 30)
        let task = Task { try await cancellable.complete(callFor(Referee())) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancelledPID = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(cancelledPID, 0), -1)
    }

    @MainActor
    func testSettingsPersistAndInvalidateVerification() throws {
        let suite = "ChessArena.LC0Tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = LC0Connection(defaults: defaults)
        connection.settings.moveSeconds = 7
        connection.settings.backend = "eigen"
        let restored = LC0Connection(defaults: defaults)
        XCTAssertEqual(restored.settings.moveSeconds, 7)
        XCTAssertEqual(restored.settings.backend, "eigen")
    }

    func testInstalledLC0PlaysBothSides() async throws {
        guard ProcessInfo.processInfo.environment["CHESSARENA_LIVE_LC0"] == "1" else { throw XCTSkip("Opt-in installed LC0 / Metal test") }
        let transport = LC0Transport(settings: .init(moveSeconds: 1))
        var referee = Referee()
        for _ in 0..<4 {
            let result = try await transport.complete(callFor(referee))
            let move = try XCTUnwrap(ChatParser.moveIntent(from: result)?.move)
            guard case .accepted = referee.submit(rawMove: move, taunt: "") else { return XCTFail("LC0 supplied illegal move") }
            print("LC0 live accepted: \(move)")
        }
        XCTAssertEqual(referee.accepted.count, 4)
    }
}

private func callFor(_ referee: Referee) -> ChatCall {
    var call = ChatCall(url: LC0Transport.localURL, apiKey: "", model: "Leela Chess Zero", system: "", user: "", route: .lc0)
    call.chessPosition = LC0Position(referee: referee)
    return call
}

private func engineFixture(_ body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("fake-lc0")
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

private final class NoLC0HTTP: ChatTransport {
    func complete(_ call: ChatCall) async throws -> String { XCTFail("LC0 must never use HTTP"); throw ChatError.transport }
}
