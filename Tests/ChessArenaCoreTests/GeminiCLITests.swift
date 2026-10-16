import Darwin
import Foundation
import XCTest
@testable import ChessArenaCore

final class GeminiCLITests: XCTestCase {
    func testEnvelopeAndSafeErrors() throws {
        func output(_ text: String, _ stderr: String = "", _ status: Int32 = 0) -> CLIOutput {
            CLIOutput(stdout: Data(text.utf8), stderr: Data(stderr.utf8), status: status)
        }
        let text = try GeminiCLI.parse(output(#"{"status":"SUCCESS","structured_output":{"move":"e2e4","taunt":"Go."},"response":"metadata must not leak"}"#))
        XCTAssertEqual(ChatParser.moveIntent(from: text)?.move, "e2e4")
        XCTAssertFalse(text.contains("metadata"))
        XCTAssertEqual(try GeminiCLI.parse(output(#"{"status":"SUCCESS","num_turns":1,"response":"Next game, develop before attacking."}"#)),
                       "Next game, develop before attacking.")
        XCTAssertThrowsError(try GeminiCLI.parse(output(#"{"status":"SUCCESS","response":"partial"}"#, "[agy] print timeout after 30s"))) {
            XCTAssertEqual($0 as? ChatError, .cli(.timeout))
        }
        for fixture in [#"{"status":"WAITING","response":"e2e4"}"#, #"{"status":"SUCCESS","response":""}"#, "not JSON"] {
            XCTAssertThrowsError(try GeminiCLI.parse(output(fixture))) { XCTAssertNotEqual($0 as? ChatError, .unreadable) }
        }
        XCTAssertThrowsError(try GeminiCLI.parse(output(#"{"status":"FAILURE","error":"not currently available in your location secret-token"}"#))) {
            XCTAssertEqual($0 as? ChatError, .cli(.region))
            XCTAssertFalse(($0 as? ChatError)?.userMessage.contains("secret-token") ?? true)
        }
        XCTAssertThrowsError(try GeminiCLI.parse(output(#"{"status":"SUCCESS","response":"e2e4"}"#, "Tool denied: secret"))) {
            XCTAssertEqual($0 as? ChatError, .cli(.tools))
        }
    }

    func testCatalogAndEnvironmentExcludeKeys() {
        let models = GeminiCLI.parseModels(Data("Fetching available models...\ngemini-4-argon-medium\tGemini 4 Argon (Medium)\ngemini-3.8-flash-high\tFlash\nclaude-opus\tClaude\ngemini-3.8-flash-high\tDuplicate\ngemini-foo;echo\tInvalid\n".utf8))
        XCTAssertEqual(models.map(\.id), ["gemini-4-argon-medium", "gemini-3.8-flash-high"])
        XCTAssertTrue(GeminiCLI.isSupportedVersion("1.3.3\n"))
        XCTAssertTrue(GeminiCLI.isSupportedVersion("1.4.0\n"))
        XCTAssertTrue(GeminiCLI.isSupportedVersion("1.4.1-build123"))
        XCTAssertFalse(GeminiCLI.isSupportedVersion("1.3.2"))
        XCTAssertFalse(GeminiCLI.isSupportedVersion("2.0.0"))
        XCTAssertEqual(GeminiCLIError.classify("Error: timed out waiting for available models"), .timeout)
        let env = GeminiCLI.environment(from: ["HOME": "/test", "GEMINI_API_KEY": "secret", "OPENAI_API_KEY": "secret", "AGY_LLM_GATEWAY_URL": "remote", "HTTPS_PROXY": "http://localhost:1234"])
        XCTAssertEqual(env["HOME"], "/test")
        XCTAssertEqual(env["HTTPS_PROXY"], "http://localhost:1234")
        XCTAssertNil(env["GEMINI_API_KEY"]); XCTAssertNil(env["AGY_LLM_GATEWAY_URL"])
    }

    func testSettingsFailClosedWithoutChangingProfile() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".gemini/antigravity-cli")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        let cli = GeminiCLI(binary: "/unused", home: home)
        try cli.validateSettings()
        let credits = Data(#"{"useG1Credits":true}"#.utf8)
        try credits.write(to: file)
        XCTAssertThrowsError(try cli.validateSettings()) { XCTAssertEqual($0 as? ChatError, .cli(.credits)) }
        XCTAssertEqual(try Data(contentsOf: file), credits)
        try Data(#"{"useG1Credits":false,"hooks":{"test":"do something"}}"#.utf8).write(to: file)
        XCTAssertThrowsError(try cli.validateSettings()) { XCTAssertEqual($0 as? ChatError, .cli(.customizations)) }
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try cli.validateSettings())
    }

    func testLiteralArgumentsConcurrentOutputAndLimit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try executable("printf '%s' \"$1\"\nprintf 'diagnostic' >&2\n", in: directory)
        let literal = "quotes '\" $(touch SHOULD_NOT_EXIST) `touch OTHER`\nsecond line"
        let output = try await LocalCLIProcess().run(binary: script.path, arguments: [literal], directory: directory, environment: ["PATH": "/usr/bin:/bin"], timeout: 3)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), literal)
        XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self), "diagnostic")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SHOULD_NOT_EXIST").path))
        let flooding = try executable("while :; do printf '01234567890123456789'; printf '01234567890123456789' >&2; done\n", in: directory)
        do {
            _ = try await LocalCLIProcess().run(binary: flooding.path, arguments: [], directory: directory, environment: [:], timeout: 3, limit: 1000)
            XCTFail("Expected bounded output")
        } catch { XCTAssertEqual(error as? ChatError, .cli(.outputLimit)) }
    }

    func testTimeoutAndCancellationKillProcessGroup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try executable("sleep 60 &\necho $! > child.pid\nwait\n", in: directory)
        do {
            _ = try await LocalCLIProcess().run(binary: script.path, arguments: [], directory: directory, environment: ["PATH": "/usr/bin:/bin"], timeout: 1.0)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? ChatError, .cli(.timeout)) }
        try await assertChildStopped(directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("child.pid"))
        let task = Task { try await LocalCLIProcess().run(binary: script.path, arguments: [], directory: directory, environment: ["PATH": "/usr/bin:/bin"], timeout: 30) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("child.pid").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await assertChildStopped(directory)
    }

    func testCompleteUsesLocalProcessAndPrivateAgent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try executable("""
        if [ "$1" = '--version' ]; then printf '1.3.3\\n'; exit; fi
        test -f .agents/agents/chessarena-player.md || exit 9
        /usr/bin/grep -F 'tools: []' .agents/agents/chessarena-player.md >/dev/null || exit 10
        test "$1" = '--print' || exit 11
        case "$2" in *PRIVATE_NOTES*) ;; *) exit 12;; esac
        case "$2" in *NEXT_GAME_ADVICE*) ;; *) exit 15;; esac
        test "$3" = '--model' || exit 13
        test "$4" = 'gemini-selected' || exit 14
        printf '%s' '{"status":"SUCCESS","num_turns":1,"response":"{\\"move\\":\\"e2e4\\",\\"taunt\\":\\"Go.\\"}"}'
        """, in: directory)
        let cli = GeminiCLI(binary: script.path, home: directory)
        let response = try await cli.complete(ChatCall(url: URL(string: "local-cli://antigravity")!, apiKey: "NOT_FOR_CLI", model: "gemini-selected", system: "chess", user: "position", selfNotes: "PRIVATE_NOTES", route: .geminiCLI, gameAdvice: "NEXT_GAME_ADVICE"))
        XCTAssertEqual(ChatParser.moveIntent(from: response)?.move, "e2e4")
    }

    @MainActor
    func testMissingCLIRouteNeverFallsBackToHTTP() async throws {
        let http = ScriptedChat()
        let transport = ArenaChatTransport(connection: nil, api: http)
        let seat = PlayerConfiguration(provider: .gemini).seat(side: .white, grokKey: "grok-secret", chatKey: "openai-secret")
        XCTAssertTrue(seat.apiKey.isEmpty)
        let call = ChatCall(url: seat.completionsURL, apiKey: seat.apiKey, model: seat.model, system: "chess", user: "position", route: seat.route)
        do { _ = try await transport.complete(call); XCTFail("Expected local CLI error") }
        catch { XCTAssertEqual(error as? ChatError, .cli(.missing)) }
        XCTAssertTrue(http.calls.isEmpty)
        XCTAssertEqual(transport.requestURL(for: call).scheme, "local-cli")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func executable(_ content: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try ("#!/bin/sh\n" + content).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func assertChildStopped(_ directory: URL) async throws {
        let text = try String(contentsOf: directory.appendingPathComponent("child.pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Child process survived cancellation")
    }
}
