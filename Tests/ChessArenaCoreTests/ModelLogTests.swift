import XCTest
@testable import ChessArenaCore

@MainActor
final class ModelLogTests: XCTestCase {
    private func call(key: String = "private-test-secret") -> ChatCall {
        ChatCall(url: URL(string: "https://example.com/v1/chat/completions")!, apiKey: key, model: "test-model",
                 system: "Play chess.", user: "FEN: position\nLegal UCI: e2e4")
    }

    func testRequestAndReplyArePairedAndSecretsAreRedactedBeforePublication() throws {
        let log = ModelLog()
        var request = call()
        request.system = "Do not repeat private-test-secret"
        let id = log.begin(request, context: "Ход белых", endpoint: URL(string: "https://user:password@example.com/v1/responses?api_key=secret#fragment")!)
        XCTAssertEqual(log.entries[0].status, .pending)
        XCTAssertEqual(log.entries[0].endpoint, "https://example.com/v1/responses")
        XCTAssertFalse(log.entries[0].text.contains(request.apiKey))
        log.succeed(id, response: "e2e4 private-test-secret Bearer opaque-token xai-1234567890", secrets: [request.apiKey])
        let entry = try XCTUnwrap(log.entries.first)
        XCTAssertEqual(entry.status, .received)
        XCTAssertNotNil(entry.duration)
        XCTAssertTrue(entry.response?.contains("e2e4") == true)
        for secret in [request.apiKey, "opaque-token", "xai-1234567890", "password"] {
            XCTAssertFalse(entry.text.contains(secret))
        }
        log.fail(id, error: ChatError.timeout)
        XCTAssertEqual(log.entries[0].status, .received)
    }

    func testTimeoutHTTPErrorAndCancellationRemainDistinct() {
        let log = ModelLog()
        let request = call()
        let timeout = log.begin(request, context: "Ведущий", endpoint: request.url)
        log.fail(timeout, error: ChatError.timeout)
        XCTAssertEqual(log.entries[0].error, ChatError.timeout.userMessage)
        let http = log.begin(request, context: "Игрок", endpoint: request.url)
        log.fail(http, error: ChatError.http(status: 429, reason: .quota))
        XCTAssertTrue(log.entries[0].error?.contains("429") == true)
        let cancelled = log.begin(request, context: "Игрок", endpoint: request.url)
        log.fail(cancelled, error: CancellationError())
        XCTAssertEqual(log.entries[0].status, .cancelled)
        let unknown = log.begin(request, context: "Игрок", endpoint: request.url)
        log.fail(unknown, error: NSError(domain: "private-test-secret", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bearer secret"]))
        XCTAssertFalse(log.entries[0].text.contains("secret"))
    }

    func testClearAndEvictionDoNotResurrectPendingRequests() {
        let log = ModelLog(capacity: 2)
        let request = call()
        let first = log.begin(request, context: "first", endpoint: request.url)
        _ = log.begin(request, context: "second", endpoint: request.url)
        _ = log.begin(request, context: "third", endpoint: request.url)
        XCTAssertEqual(log.entries.map(\.context), ["third", "second"])
        log.succeed(first, response: "late")
        XCTAssertEqual(log.entries.count, 2)
        let pending = log.entries[0].id
        log.clear()
        log.fail(pending, error: ChatError.timeout)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testTokenRedactionPrecedesTextTruncation() {
        let secret = String(repeating: "x", count: 100)
        let text = String(repeating: "a", count: 31_990) + secret
        let sanitized = ModelLog.sanitize(text, secrets: [secret])
        XCTAssertFalse(sanitized.contains("xxxxxxxx"))
        let tokens = #"{"access_token":"opaque-value","refresh_token":"another-value","id_token":"eyJabc.def.ghi"}"#
        let safe = ModelLog.sanitize(tokens)
        for token in ["opaque-value", "another-value", "eyJabc.def.ghi"] { XCTAssertFalse(safe.contains(token)) }
    }

    func testRejectedMovePreservesTheModelReply() {
        let log = ModelLog()
        let request = call()
        let id = log.begin(request, context: "Игрок", endpoint: request.url)
        log.succeed(id, response: #"{"move":"e2e5"}"#)
        log.rejectMove(id, reason: "Недопустимый ход e2e5")
        XCTAssertEqual(log.entries[0].status, .failed)
        XCTAssertTrue(log.entries[0].error?.contains("e2e5") == true)
        XCTAssertTrue(log.entries[0].response?.contains("e2e5") == true)
    }
}
