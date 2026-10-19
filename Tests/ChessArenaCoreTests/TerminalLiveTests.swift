import Foundation
import XCTest
@testable import ChessArenaCore

final class TerminalLiveTests: XCTestCase {
    /// Explicit opt-in: exactly two independent calls, each capped at the existing 16,384 budget.
    /// Does not mutate the user's session, score, memory or archives.
    func testDeepSeekHistoricalPositionsAtUnchangedBudget() async throws {
        guard ProcessInfo.processInfo.environment["CHESSARENA_DEEPSEEK_TERMINAL_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in paid DeepSeek diagnosis: two calls, max_tokens 16384 each")
        }
        let key = try XCTUnwrap(KeychainSecretStore(service: "com.chessarena.broadcast").load(account: "deepseek"))
        let positions = [
            "r2q1rk1/1p1nbppp/p2pbn2/4p3/4P3/1NN1BP2/PPPQ2PP/2KR1B1R w - - 5 11",
            "r2q1rk1/3nbppp/p2pb3/4p1Pn/1p2P3/1N2BP2/PPPQN2P/2KR1B1R w - - 2 14"
        ]
        var rows: [[String: Any]] = []
        for fen in positions {
            let board = try XCTUnwrap(Position.position(fen: fen))
            let prompt = Prompts.player(side: .white, fen: fen, legal: board.legalMoves().map(\.uci).sorted(), history: [], rejection: nil)
            var call = ChatCall(url: ModelCatalog.deepSeekAPI.appendingPathComponent("chat/completions"), apiKey: key,
                                model: ModelCatalog.deepSeekModel, system: prompt.system, user: prompt.user, route: .deepseek, effort: "high", responseFormat: .jsonObject)
            call.maxOutputTokens = 16_384
            let capture = LiveMetadata()
            let started = Date()
            var row: [String: Any] = ["fen": fen, "model": call.model, "max_tokens": 16_384, "thinking": "high"]
            do {
                let text = try await ResponseTrace.$receive.withValue({ metadata in await capture.set(metadata) }) {
                    try await DeepSeekTransport(timeout: 600).complete(call)
                }
                let intent = try XCTUnwrap(ChatParser.moveIntent(from: text))
                var referee = Referee(position: board)
                switch referee.submit(rawMove: intent.move, taunt: "") {
                case .accepted(let move, _): row["outcome"] = "legalMove"; row["move"] = move.move.uci
                default: row["outcome"] = "illegalMove"; XCTAssertNil(referee.end)
                }
            } catch let error as ChatError {
                row["outcome"] = error.diagnosticCode
                row["pausesWithoutRetry"] = error.pausesWithoutRetry
            }
            row["seconds"] = Date().timeIntervalSince(started)
            if let metadata = await capture.value {
                row["response"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata))
            }
            rows.append(row)
            let line = "DEEPSEEK_TERMINAL_SMOKE " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self) + "\n"
            try FileHandle.standardError.write(contentsOf: Data(line.utf8))
            // Save after each call, retaining partial evidence if a later call is interrupted.
            if let path = ProcessInfo.processInfo.environment["CHESSARENA_TERMINAL_REPORT"] {
                try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        XCTAssertEqual(rows.count, 2)
    }
}

private actor LiveMetadata {
    var value: ResponseMetadata?
    func set(_ metadata: ResponseMetadata) { value = metadata }
}
