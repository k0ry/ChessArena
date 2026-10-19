import Foundation
import XCTest
@testable import ChessArenaCore

/// Explicit clock for deadline/countdown tests; safe across the task-local transport boundary.
final class ManualRequestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func set(_ value: TimeInterval) { lock.withLock { self.value = value } }
}

@MainActor
final class RequestTimingTests: XCTestCase {
    func testSharedBudgetIncludesPreparationAndRejectsLateCompletion() async throws {
        let clock = ManualRequestClock()
        let timing = RequestTiming(seconds: 600, now: { clock.now })
        clock.set(130)
        XCTAssertEqual(timing.remaining, 470)
        let value = try await RequestDeadline.run(timing: timing) {
            XCTAssertEqual(try RequestTiming.timeout(fallback: 600), 470)
            return "response after the old limit"
        }
        XCTAssertEqual(value, "response after the old limit")
        do {
            _ = try await RequestDeadline.run(timing: timing) {
                clock.set(600)
                return "late legal-looking response"
            }
            XCTFail("Expired response must not win the deadline race")
        } catch { XCTAssertEqual(error as? ChatError, .timeout) }
        XCTAssertNil(RequestTiming.current, "scope must not leak into another request")
    }

    func testConcurrentRoleBudgetsAreIndependent() async throws {
        async let host: Double = RequestDeadline.run(seconds: 90) {
            try await Task.sleep(nanoseconds: 5_000_000)
            return try RequestTiming.timeout(fallback: 600)
        }
        async let player: Double = RequestDeadline.run(seconds: 600) {
            try await Task.sleep(nanoseconds: 5_000_000)
            return try RequestTiming.timeout(fallback: 600)
        }
        let values = try await (host, player)
        XCTAssertTrue((89...90).contains(values.0))
        XCTAssertTrue((599...600).contains(values.1))
    }

    func testKnownTimeoutsRetryButConfigurationFailuresDoNot() {
        for error: ChatError in [.timeout, .cli(.timeout), .cli(.connection), .claudeCLI(.timeout), .claudeCLI(.connection), .lc0(.timeout)] {
            XCTAssertFalse(error.pausesWithoutRetry, "\(error)")
        }
        for error: ChatError in [.cli(.authentication), .cli(.quota), .cli(.execution), .cli(.tools), .cli(.credits), .cli(.invalidResponse),
                                 .claudeCLI(.authentication), .claudeCLI(.quota), .claudeCLI(.apiKeyMode), .response(.truncated)] {
            XCTAssertTrue(error.pausesWithoutRetry, "\(error)")
        }
        XCTAssertEqual(ChatError.cli(.timeout).diagnosticCode, "gemini_cli_timeout")
        XCTAssertEqual(ChatError.timeout.timeoutSource(deadlineExpired: true), "request_deadline")
    }

    func testHTTPTransportsReceiveRemainingRoleBudget() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimingRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cases: [(ChatRoute, ChatTransport)] = [
            (.http, URLSessionChatTransport(session: session)),
            (.deepseek, DeepSeekTransport(session: session)),
            (.anthropic, AnthropicTransport(session: session))
        ]
        for (route, transport) in cases {
            let clock = ManualRequestClock()
            let timing = RequestTiming(seconds: 90, now: { clock.now })
            clock.set(12)
            TimingRequestProtocol.observedTimeout = nil
            let call = ChatCall(url: URL(string: "https://fixture.invalid/completion")!, apiKey: "fixture", model: "fixture", system: "chess", user: "move", route: route)
            do {
                _ = try await RequestDeadline.run(timing: timing) { try await transport.complete(call) }
                XCTFail("fixture returns a deliberate network error")
            } catch { XCTAssertEqual(error as? ChatError, .transport) }
            XCTAssertEqual(TimingRequestProtocol.observedTimeout, 78)
        }
    }

    func testPausePresentationAndLegacyDecodeAreHonest() throws {
        let retry = RequestStatus(mode: .retryScheduled, attempt: 2, secondsLeft: 3)
        XCTAssertEqual(retry.detail(.russian), "Автоповтор через 3 с · попытка 2/3")
        let manual = RequestStatus(mode: .manualPause, attempt: 3)
        XCTAssertEqual(manual.title(.russian), "ПАУЗА")
        XCTAssertFalse(manual.detail(.russian).lowercased().contains("авто"))
        var picture = BroadcastPicture.empty
        picture.requestStatus = retry
        XCTAssertEqual(try JSONDecoder().decode(BroadcastPicture.self, from: JSONEncoder().encode(picture)).requestStatus, retry)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(picture)) as? [String: Any])
        legacy.removeValue(forKey: "requestStatus")
        let decoded = try JSONDecoder().decode(BroadcastPicture.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.requestStatus)
        picture.pausedPlayer = "Gemini"
        picture.line = "Retrying automatically…"
        picture.clearPendingRequest(language: .russian)
        XCTAssertNil(picture.requestStatus)
        XCTAssertNil(picture.pausedPlayer)
        XCTAssertFalse(picture.line.contains("automatically"))
    }
}

private final class TimingRequestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stored: TimeInterval?
    static var observedTimeout: TimeInterval? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.observedTimeout = request.timeoutInterval
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }
    override func stopLoading() {}
}
