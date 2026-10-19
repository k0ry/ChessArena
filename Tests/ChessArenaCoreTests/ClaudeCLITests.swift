import Foundation
import XCTest
@testable import ChessArenaCore

final class ClaudeCLITests: XCTestCase {
    func testResultEnvelopeAndSafeErrors() throws {
        func output(_ text: String, _ stderr: String = "", _ status: Int32 = 0) -> CLIOutput {
            CLIOutput(stdout: Data(text.utf8), stderr: Data(stderr.utf8), status: status)
        }
        let ok = #"{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"{\"move\":\"e2e4\",\"taunt\":\"Go.\"}","session_id":"s","permission_denials":[]}"#
        XCTAssertEqual(ChatParser.moveIntent(from: try ClaudeCLI.parse(output(ok)))?.move, "e2e4")
        XCTAssertEqual(try ClaudeCLI.parse(output("Warning: something\n" + ok)), #"{"move":"e2e4","taunt":"Go."}"#)

        let token = "sk-ant-oat01-SECRET-TOKEN"
        let unauthenticated = #"{"type":"result","subtype":"success","is_error":true,"num_turns":1,"result":"Failed to authenticate. API Error: 401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"OAuth access token is invalid. "# + token + #"\"}}","permission_denials":[]}"#
        XCTAssertThrowsError(try ClaudeCLI.parse(output(unauthenticated, "", 1))) {
            XCTAssertEqual($0 as? ChatError, .claudeCLI(.authentication))
            XCTAssertFalse(($0 as? ChatError)?.userMessage.contains(token) ?? true)
        }
        XCTAssertThrowsError(try ClaudeCLI.parse(output(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"You've hit your usage limit. Resets at 3pm."}"#, "", 1))) {
            XCTAssertEqual($0 as? ChatError, .claudeCLI(.quota))
        }
        XCTAssertThrowsError(try ClaudeCLI.parse(output(#"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 400 Your credit balance is too low"}"#, "", 1))) {
            XCTAssertEqual($0 as? ChatError, .claudeCLI(.apiKeyMode))
        }
        XCTAssertThrowsError(try ClaudeCLI.parse(output(#"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 404 model: claude-nope not found"}"#, "", 1))) {
            XCTAssertEqual($0 as? ChatError, .claudeCLI(.model))
        }
        XCTAssertThrowsError(try ClaudeCLI.parse(output(#"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 400 Claude Code 2.1.29 does not support this model; version 2.1.251 or newer is required"}"#, "", 1))) {
            XCTAssertEqual($0 as? ChatError, .claudeCLI(.outdated))
            XCTAssertTrue(($0 as? ChatError)?.userMessage.contains("claude update") ?? false)
        }
        XCTAssertThrowsError(try ClaudeCLI.parse(output(#"{"type":"result","subtype":"success","is_error":false,"result":"e2e4","permission_denials":[{"tool_name":"Bash"}]}"#))) {
            XCTAssertEqual($0 as? ChatError, .claudeCLI(.tools))
        }
        XCTAssertThrowsError(try ClaudeCLI.parse(output(#"{"type":"result","subtype":"success","is_error":false,"result":"   "}"#))) {
            XCTAssertEqual($0 as? ChatError, .claudeCLI(.invalidResponse))
        }
        XCTAssertThrowsError(try ClaudeCLI.parse(output("not json", "", 1))) { XCTAssertEqual($0 as? ChatError, .claudeCLI(.execution)) }
        XCTAssertThrowsError(try ClaudeCLI.parse(output("", "Error: request timed out", 1))) { XCTAssertEqual($0 as? ChatError, .claudeCLI(.timeout)) }
        XCTAssertTrue(ChatError.claudeCLI(.quota).pausesWithoutRetry)
        XCTAssertTrue(ChatError.refused.pausesWithoutRetry)
        XCTAssertTrue(ChatError.http(status: 401, reason: .authentication).pausesWithoutRetry)
    }

    func testVersionModelsArgumentsAndEnvironment() {
        XCTAssertTrue(ClaudeCLI.isSupportedVersion("2.1.29 (Claude Code)\n"))
        XCTAssertTrue(ClaudeCLI.isSupportedVersion("2.1.0"))
        XCTAssertTrue(ClaudeCLI.isSupportedVersion("2.4.1-beta (Claude Code)"))
        XCTAssertFalse(ClaudeCLI.isSupportedVersion("2.0.99 (Claude Code)"))
        XCTAssertFalse(ClaudeCLI.isSupportedVersion("3.0.0 (Claude Code)"))
        XCTAssertFalse(ClaudeCLI.isSupportedVersion("garbage"))

        for model in ["opus", "sonnet", "haiku", "claude-opus-5-5", "claude-sonnet-4-5-20250929"] { XCTAssertTrue(ClaudeCLI.validModel(model), model) }
        for model in ["gpt-5", "opus;rm -rf", "", "claude opus"] { XCTAssertFalse(ClaudeCLI.validModel(model), model) }
        XCTAssertEqual(ClaudeCLI.aliases.map(\.id), ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "opus", "sonnet", "haiku"])
        XCTAssertTrue(ClaudeCLI.aliases.allSatisfy { ClaudeCLI.validModel($0.id) })

        let call = ChatCall(url: ClaudeCLI.localURL, apiKey: "", model: " sonnet ", system: "SYSTEM RULES", user: "FEN: start",
                            selfNotes: "PRIVATE_NOTES", route: .claudeCLI, gameAdvice: "NEXT_GAME_ADVICE", effort: "high")
        let arguments = ClaudeCLI.arguments(for: call)
        XCTAssertEqual(arguments[0], "-p")
        XCTAssertTrue(arguments[1].hasPrefix("FEN: start"))
        XCTAssertTrue(arguments[1].contains("NEXT_GAME_ADVICE"))
        XCTAssertTrue(arguments[1].contains("PRIVATE_NOTES"))
        XCTAssertLessThan(arguments[1].range(of: "NEXT_GAME_ADVICE")!.lowerBound, arguments[1].range(of: "PRIVATE_NOTES")!.lowerBound)
        XCTAssertFalse(arguments[1].contains("SYSTEM RULES"))
        func value(after flag: String) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
        XCTAssertEqual(value(after: "--model"), "sonnet")
        XCTAssertEqual(value(after: "--system-prompt"), "SYSTEM RULES")
        XCTAssertEqual(value(after: "--output-format"), "json")
        XCTAssertEqual(value(after: "--tools"), "")
        XCTAssertEqual(value(after: "--setting-sources"), "")
        XCTAssertEqual(value(after: "--permission-mode"), "dontAsk")
        for flag in ["--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"] { XCTAssertTrue(arguments.contains(flag), flag) }
        XCTAssertFalse(arguments.contains { $0.contains("effort") })

        let env = ClaudeCLI.environment(from: ["HOME": "/test", "ANTHROPIC_API_KEY": "secret", "CLAUDE_CODE_OAUTH_TOKEN": "secret",
                                               "ANTHROPIC_BASE_URL": "http://proxy", "HTTPS_PROXY": "http://localhost:1234", "PATH": "/evil"])
        XCTAssertEqual(env["HOME"], "/test")
        XCTAssertEqual(env["HTTPS_PROXY"], "http://localhost:1234")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(env["DISABLE_AUTOUPDATER"], "1")
        XCTAssertEqual(env["USER"], NSUserName(), "the CLI locates its Keychain login by USER")
        XCTAssertEqual(env["LOGNAME"], NSUserName())
        let explicit = ClaudeCLI.environment(from: ["USER": "alice", "LOGNAME": "alice"], userName: "bob")
        XCTAssertEqual(explicit["USER"], "alice"); XCTAssertEqual(explicit["LOGNAME"], "alice")
        XCTAssertEqual(ClaudeCLI.environment(from: [:], userName: "bob")["USER"], "bob")
        XCTAssertNil(env["ANTHROPIC_API_KEY"]); XCTAssertNil(env["CLAUDE_CODE_OAUTH_TOKEN"]); XCTAssertNil(env["ANTHROPIC_BASE_URL"])
    }

    func testAccountValidationFailsClosedWithoutChangingConfig() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let cli = ClaudeCLI(binary: "/unused", home: home)
        XCTAssertThrowsError(try cli.validateAccount()) { XCTAssertEqual($0 as? ChatError, .claudeCLI(.authentication)) }
        let file = home.appendingPathComponent(".claude.json")
        try Data(#"{"numStartups":3}"#.utf8).write(to: file)
        XCTAssertThrowsError(try cli.validateAccount()) { XCTAssertEqual($0 as? ChatError, .claudeCLI(.authentication)) }
        let apiKey = Data(#"{"primaryApiKey":"sk-ant-api03-secret","oauthAccount":{"billingType":"api"}}"#.utf8)
        try apiKey.write(to: file)
        XCTAssertThrowsError(try cli.validateAccount()) { XCTAssertEqual($0 as? ChatError, .claudeCLI(.apiKeyMode)) }
        XCTAssertEqual(try Data(contentsOf: file), apiKey)
        try Data(#"{"oauthAccount":{"billingType":"stripe_subscription","organizationType":"claude_max","hasExtraUsageEnabled":true,"emailAddress":"private@example.com"}}"#.utf8).write(to: file)
        let info = try cli.validateAccount()
        XCTAssertEqual(info, ClaudeAccountInfo(billingType: "stripe_subscription", organizationType: "claude_max", extraUsageEnabled: true))
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try cli.validateAccount()) { XCTAssertEqual($0 as? ChatError, .claudeCLI(.authentication)) }
    }

    func testCompleteUsesLocalProcessWithIsolationFlags() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"oauthAccount":{"billingType":"stripe_subscription"}}"#.utf8).write(to: directory.appendingPathComponent(".claude.json"))
        let script = try executable("""
        if [ "$1" = '--version' ]; then printf '2.1.29 (Claude Code)\\n'; exit; fi
        test -z "$ANTHROPIC_API_KEY" || exit 20
        test "$1" = '-p' || exit 11
        case "$2" in *PRIVATE_NOTES*) ;; *) exit 12;; esac
        case "$2" in *NEXT_GAME_ADVICE*) ;; *) exit 15;; esac
        test "$3" = '--output-format' || exit 16
        test "$5" = '--model' || exit 13
        test "$6" = 'claude-selected' || exit 14
        test "$7" = '--system-prompt' || exit 17
        test "$8" = 'chess' || exit 18
        test "$9" = '--tools' || exit 19
        test -z "${10}" || exit 21
        ls -A | grep -q . && exit 22
        printf '%s' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"{\\"move\\":\\"e2e4\\",\\"taunt\\":\\"Go.\\"}","permission_denials":[]}'
        """, in: directory)
        let cli = ClaudeCLI(binary: script.path, home: directory)
        let response = try await cli.complete(ChatCall(url: ClaudeCLI.localURL, apiKey: "NOT_FOR_CLI", model: "claude-selected", system: "chess",
                                                       user: "position", selfNotes: "PRIVATE_NOTES", route: .claudeCLI, gameAdvice: "NEXT_GAME_ADVICE"))
        XCTAssertEqual(ChatParser.moveIntent(from: response)?.move, "e2e4")
        do {
            _ = try await cli.complete(ChatCall(url: ClaudeCLI.localURL, apiKey: "", model: "gpt-5", system: "chess", user: "position", route: .claudeCLI))
            XCTFail("invalid model must be rejected before spawning")
        } catch { XCTAssertEqual(error as? ChatError, .claudeCLI(.model)) }
        do {
            _ = try await ClaudeCLI(binary: directory.appendingPathComponent("absent").path, home: directory).checkVersion()
            XCTFail("missing binary")
        } catch { XCTAssertEqual(error as? ChatError, .claudeCLI(.missing)) }
        let old = try executable("printf '2.0.5 (Claude Code)\\n'\n", in: directory)
        do { try await ClaudeCLI(binary: old.path, home: directory).checkVersion(); XCTFail("old version") }
        catch { XCTAssertEqual(error as? ChatError, .claudeCLI(.incompatible)) }
    }

    @MainActor
    func testSubscriptionRouteNeverFallsBackToHTTPOrAPIKey() async throws {
        let http = ScriptedChat()
        let api = ScriptedChat()
        let transport = ArenaChatTransport(connection: nil, api: http, anthropic: api)
        let keys = ProviderKeys(grok: "grok-secret", chatGPT: "openai-secret", anthropic: "anthropic-secret")
        let seat = PlayerConfiguration(provider: .claude).seat(side: .white, keys: keys)
        XCTAssertEqual(seat.route, .claudeCLI)
        XCTAssertTrue(seat.apiKey.isEmpty)
        XCTAssertEqual(seat.completionsURL, ClaudeCLI.localURL)
        let call = ChatCall(url: seat.completionsURL, apiKey: seat.apiKey, model: seat.model, system: "chess", user: "position", route: seat.route)
        do { _ = try await transport.complete(call); XCTFail("Expected local CLI error") }
        catch { XCTAssertEqual(error as? ChatError, .claudeCLI(.missing)) }
        XCTAssertTrue(http.calls.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertEqual(transport.requestURL(for: call), ClaudeCLI.localURL)

        var withKey = keys; withKey.claudeAccess = .apiKey
        let apiSeat = PlayerConfiguration(provider: .claude).seat(side: .white, keys: withKey)
        XCTAssertEqual(apiSeat.route, .anthropic)
        XCTAssertEqual(apiSeat.apiKey, "anthropic-secret")
        XCTAssertEqual(apiSeat.completionsURL.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testSessionDefaultsToSubscriptionForLegacyFiles() throws {
        let state = SavedSession(game: nil, series: MatchSeries(), white: .init(provider: .claude), black: .init(provider: .grok),
                                 hostModel: "m", language: .russian, useChatGPTLogin: true,
                                 camera: .init(manual: false, yaw: 0, pitch: 0, distance: 12), claudeAccess: .apiKey)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(SavedSession.self, from: data).claudeAccess, .apiKey)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "claudeAccess")
        let old = try JSONDecoder().decode(SavedSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.claudeAccess)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-cli-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executable(_ content: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("fake-claude-" + UUID().uuidString)
        try ("#!/bin/sh\n" + content).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
