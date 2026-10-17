import Foundation
import XCTest
@testable import ChessArenaCore

final class PersonaTests: XCTestCase {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    func testEightDistinctPersonasWithGuardrails() {
        XCTAssertEqual(PlayerPersona.allCases.count, 8)
        XCTAssertEqual(Set(PlayerPersona.allCases.map { $0.displayName(.english) }).count, 8)
        XCTAssertEqual(Set(PlayerPersona.allCases.map { $0.displayName(.russian) }).count, 8)
        for persona in PlayerPersona.allCases {
            let text = persona.instruction
            XCTAssertTrue(text.contains("no quotations"), persona.rawValue)
            XCTAssertTrue(text.contains("never name or claim to be any real person"), persona.rawValue)
            XCTAssertTrue(text.contains("no slurs"), persona.rawValue)
            XCTAssertTrue(text.contains("never the move"), persona.rawValue)
            XCTAssertFalse(text.contains(persona.displayName(.english)), "instruction must not name the person")
        }
        XCTAssertEqual(CommentaryStyle.allCases, [.zadornov])
        XCTAssertEqual(CommentaryStyle.turn(7), .zadornov)
        XCTAssertFalse(CommentaryStyle.zadornov.instruction.contains("House"))
    }

    func testAssignmentsAreStableUniqueAndColorIndependent() {
        var table = PersonaAssignments()
        var generator = SeededGenerator(state: 42)
        var seen: [PlayerPersona] = []
        for index in 0..<8 {
            let persona = table.assign(provider: .grok, model: "model-\(index)", using: &generator)
            XCTAssertFalse(seen.contains(persona), "first encounters draw from free personas")
            seen.append(persona)
            XCTAssertEqual(table.assign(provider: .grok, model: "model-\(index)", using: &generator), persona, "repeat lookups are stable")
        }
        XCTAssertEqual(Set(seen).count, 8)
        let ninth = table.assign(provider: .chatGPT, model: "model-9", using: &generator)
        XCTAssertTrue(PlayerPersona.allCases.contains(ninth))
        XCTAssertEqual(table.entries.count, 9)
        XCTAssertEqual(table.persona(provider: .grok, model: "model-0"), seen[0])
        XCTAssertEqual(table.persona(provider: .grok, model: " model-0 "), seen[0], "whitespace in the model id does not change the key")
        XCTAssertNil(table.persona(provider: .claude, model: "model-0"), "same model id under another provider is a different player")
    }

    func testInitialTableSeedsExistingModelsAndRoundTripsInSession() throws {
        let initial = PersonaAssignments.initial
        XCTAssertEqual(initial.persona(provider: .grok, model: ModelCatalog.grokModel), .louisCK)
        XCTAssertEqual(initial.persona(provider: .chatGPT, model: ModelCatalog.chatGPTModel), .burr)
        XCTAssertEqual(initial.persona(provider: .gemini, model: GeminiCLI.defaultModel), .carlin)
        XCTAssertEqual(initial.persona(provider: .claude, model: ModelCatalog.claudeModel), .gervais)
        XCTAssertEqual(Set(initial.entries.values).count, 4)

        var state = SavedSession(game: nil, series: MatchSeries(), white: .init(provider: .grok), black: .init(provider: .claude),
                                 hostModel: "m", language: .russian, useChatGPTLogin: true,
                                 camera: .init(manual: false, yaw: 0, pitch: 0, distance: 12), personas: initial)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(SavedSession.self, from: data).personas, initial)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "personas")
        XCTAssertNil(try JSONDecoder().decode(SavedSession.self, from: JSONSerialization.data(withJSONObject: legacy)).personas)
        state.personas = nil
        XCTAssertNil(try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(state)).personas)
    }

    func testPlayerPromptCarriesPersonaAndOpponentWithoutChangingFormat() {
        let position = Position.standard()
        let legal = position.legalMoves().map(\.uci)
        let plain = Prompts.player(side: .white, fen: position.fen, legal: legal, history: [], rejection: nil)
        let styled = Prompts.player(side: .black, fen: position.fen, legal: legal, history: [], rejection: nil, persona: .burnham)
        XCTAssertTrue(plain.system.contains("Taunt persona: deliver the taunt as a dry, sharp remark"))
        XCTAssertTrue(styled.system.contains("wordplay-heavy"))
        XCTAssertTrue(styled.system.contains("You are Black"))
        for prompt in [plain, styled] {
            XCTAssertTrue(prompt.system.contains(#"{"move":"<uci>","taunt":"#))
            XCTAssertTrue(prompt.system.contains("Reply with JSON only"))
            XCTAssertEqual(prompt.user, plain.user)
        }
        XCTAssertTrue(BroadcastLanguage.russian.prompt(styled.system).contains("aimed at your opponent"))
    }
}
