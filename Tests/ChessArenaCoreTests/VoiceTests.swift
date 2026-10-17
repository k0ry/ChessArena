import XCTest
@testable import ChessArenaCore

final class VoiceTests: XCTestCase {
    private let voices = [
        VoiceDescriptor(identifier: "en.samantha", name: "Samantha", language: "en-US", isMale: false),
        VoiceDescriptor(identifier: "en.daniel", name: "Daniel (English (UK))", language: "en-GB", isMale: true),
        VoiceDescriptor(identifier: "en.reed", name: "Reed (English (US))", language: "en-US", isMale: true),
        VoiceDescriptor(identifier: "en.eddy", name: "Eddy (English (US))", language: "en-US", isMale: true),
        VoiceDescriptor(identifier: "ru.milena", name: "Milena", language: "ru-RU", isMale: false),
    ]

    func testHostPrefersDeepMaleVoiceAndPersonasDiffer() {
        XCTAssertEqual(VoiceSelection.pick(for: .host, language: .english, from: voices)?.identifier, "en.daniel")
        XCTAssertEqual(VoiceSelection.pick(for: .persona(.burr), language: .english, from: voices)?.identifier, "en.reed")
        XCTAssertEqual(VoiceSelection.pick(for: .persona(.carrey), language: .english, from: voices)?.identifier, "en.eddy")
        // No preferred name installed: any male voice of the language, never the female default.
        XCTAssertEqual(VoiceSelection.pick(for: .persona(.carlin), language: .english, from: voices)?.isMale, true)
        // Russian has only Milena here: nil means the synthesizer falls back to the system default voice.
        XCTAssertNil(VoiceSelection.pick(for: .host, language: .russian, from: voices))
        XCTAssertFalse(VoiceSelection.hasMaleVoice(for: .russian, in: voices))
        XCTAssertTrue(VoiceSelection.hasMaleVoice(for: .english, in: voices))
        let withYuri = voices + [VoiceDescriptor(identifier: "ru.yuri", name: "Yuri", language: "ru-RU", isMale: true)]
        XCTAssertEqual(VoiceSelection.pick(for: .host, language: .russian, from: withYuri)?.identifier, "ru.yuri")
        XCTAssertEqual(VoiceSelection.pick(for: .persona(.gervais), language: .russian, from: withYuri)?.identifier, "ru.yuri")
    }

    func testProfilesHaveAnnouncerHostAndDistinctPersonaDelivery() {
        XCTAssertLessThan(VoiceProfile.host.pitch, 0.85, "the host sits low like a ring announcer")
        XCTAssertLessThan(VoiceProfile.host.rate, 0.5, "the host speaks slower than the system default")
        XCTAssertGreaterThan(VoiceProfile.host.pauseBefore, 0.2)
        let personas = PlayerPersona.allCases.map { VoiceProfile.persona($0) }
        XCTAssertEqual(Set(personas.map { "\($0.pitch)-\($0.rate)" }).count, personas.count, "every persona has its own delivery")
        for profile in personas {
            XCTAssertTrue((0.8...1.2).contains(profile.pitch), "\(profile)")
            XCTAssertTrue((0.4...0.6).contains(profile.rate), "\(profile)")
            XCTAssertFalse(profile.preferredVoiceNames(for: .english).isEmpty)
        }
    }

    @MainActor
    func testSystemUtteranceCarriesProfileDelivery() throws {
        let utterance = try XCTUnwrap(SystemVoice.makeUtterance("Sound check.", language: .english, profile: .host))
        XCTAssertEqual(utterance.pitchMultiplier, VoiceProfile.host.pitch)
        XCTAssertEqual(utterance.rate, VoiceProfile.host.rate)
        XCTAssertNotNil(utterance.voice)
        XCTAssertNil(SystemVoice.makeUtterance("   ", language: .english, profile: .host))
    }
}
