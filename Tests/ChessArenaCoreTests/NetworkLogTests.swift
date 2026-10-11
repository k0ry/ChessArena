import XCTest
@testable import ChessArenaCore

@MainActor
final class NetworkLogTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetworkLogFixture.self]
        return URLSession(configuration: config)
    }
    private func call() -> ChatCall {
        ChatCall(url: URL(string: "https://api.x.ai/v1/chat/completions?key=QUERY_SECRET")!,
                 apiKey: "HEADER_SECRET", model: "test", system: "BODY_SECRET", user: "USER_SECRET")
    }

    func testHTTPStatusSizeAndSafeErrorAreLoggedByRealTransport() async throws {
        NetworkLog.shared.clear()
        NetworkLogFixture.error = nil
        NetworkLogFixture.status = 429
        NetworkLogFixture.body = Data(#"{"error":{"code":"insufficient_quota","message":"RESPONSE_SECRET"}}"#.utf8)
        let network = session()
        defer { network.invalidateAndCancel() }
        do {
            _ = try await URLSessionChatTransport(session: network).complete(call())
            XCTFail("Expected quota failure")
        } catch { XCTAssertEqual(error as? ChatError, .http(status: 429, reason: .quota)) }
        let entry = try XCTUnwrap(NetworkLog.shared.entries.first)
        XCTAssertEqual(entry.operation, .chat)
        XCTAssertEqual(entry.endpoint, "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(entry.httpStatus, 429)
        XCTAssertEqual(entry.status, .failed)
        XCTAssertEqual(entry.receivedBytes, NetworkLogFixture.body.count)
        XCTAssertGreaterThan(entry.sentBytes ?? 0, 0)
        XCTAssertNotNil(entry.duration)
        XCTAssertTrue(entry.error?.contains("квота") == true)
        for secret in ["QUERY_SECRET", "HEADER_SECRET", "BODY_SECRET", "USER_SECRET", "RESPONSE_SECRET", "COOKIE_SECRET"] {
            XCTAssertFalse(entry.text.contains(secret))
        }
    }

    func testSuccessfulHTTPAndInvalidJSONHaveDifferentOutcomes() async throws {
        NetworkLog.shared.clear()
        NetworkLogFixture.error = nil
        NetworkLogFixture.status = 200
        NetworkLogFixture.body = Data(#"{"choices":[{"message":{"content":"e2e4"}}]}"#.utf8)
        let network = session()
        defer { network.invalidateAndCancel() }
        let transport = URLSessionChatTransport(session: network)
        let answer = try await transport.complete(call())
        XCTAssertEqual(answer, "e2e4")
        XCTAssertEqual(NetworkLog.shared.entries.first?.status, .success)
        NetworkLogFixture.body = Data("INVALID_RESPONSE_SECRET".utf8)
        do { _ = try await transport.complete(call()); XCTFail("Expected parsing failure") }
        catch { XCTAssertEqual(error as? ChatError, .unreadable) }
        XCTAssertEqual(NetworkLog.shared.entries.first?.httpStatus, 200)
        XCTAssertEqual(NetworkLog.shared.entries.first?.status, .failed)
        XCTAssertFalse(NetworkLog.shared.entries[0].text.contains("INVALID_RESPONSE_SECRET"))
    }

    func testTransportTimeoutDNSAndCancellationKeepDiagnosticCodes() async throws {
        let network = session()
        defer { network.invalidateAndCancel(); NetworkLogFixture.error = nil }
        for code: URLError.Code in [.timedOut, .dnsLookupFailed, .cancelled] {
            NetworkLog.shared.clear()
            NetworkLogFixture.error = URLError(code, userInfo: [NSLocalizedDescriptionKey: "RAW_SECRET"])
            do { _ = try await URLSessionChatTransport(session: network).complete(call()); XCTFail("Expected error") }
            catch { }
            let entry = try XCTUnwrap(NetworkLog.shared.entries.first)
            XCTAssertEqual(entry.status, code == .cancelled ? .cancelled : .failed)
            XCTAssertNil(entry.httpStatus)
            XCTAssertFalse(entry.text.contains("RAW_SECRET"))
            if code != .cancelled { XCTAssertTrue(entry.text.contains(String(code.rawValue))) }
        }
    }

    func testOAuthMetadataNeverRetainsTokensOrCredentials() async throws {
        NetworkLog.shared.clear()
        NetworkLogFixture.error = nil
        NetworkLogFixture.status = 401
        NetworkLogFixture.body = Data(#"{"access_token":"ACCESS_SECRET","refresh_token":"REFRESH_SECRET"}"#.utf8)
        var request = URLRequest(url: URL(string: "https://name:PASSWORD_SECRET@auth.openai.com/api/accounts/oauth/token?code=CODE_SECRET#FRAGMENT_SECRET")!)
        request.httpMethod = "POST"
        request.httpBody = Data("code=CODE_SECRET&refresh_token=REFRESH_SECRET".utf8)
        let network = session()
        defer { network.invalidateAndCancel() }
        let (_, response) = try await network.loggedData(for: request, operation: .token)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401, "Logging must preserve the caller's validation path")
        let entry = try XCTUnwrap(NetworkLog.shared.entries.first)
        XCTAssertEqual(entry.status, .failed)
        XCTAssertEqual(entry.endpoint, "https://auth.openai.com/api/accounts/oauth/token")
        for secret in ["ACCESS_SECRET", "REFRESH_SECRET", "PASSWORD_SECRET", "CODE_SECRET", "FRAGMENT_SECRET"] {
            XCTAssertFalse(entry.text.contains(secret))
        }
    }

    func testMissingCLIIsVisibleWithoutLeakingLocalPath() async throws {
        NetworkLog.shared.clear()
        do { try await GeminiCLI(binary: "/PRIVATE_SECRET/no-agy").checkVersion(); XCTFail("Expected missing CLI") }
        catch { XCTAssertEqual(error as? ChatError, .cli(.missing)) }
        let entry = try XCTUnwrap(NetworkLog.shared.entries.first)
        XCTAssertTrue(entry.isCLI)
        XCTAssertEqual(entry.status, .failed)
        XCTAssertNil(entry.httpStatus)
        XCTAssertFalse(entry.text.contains("PRIVATE_SECRET"))
    }

    func testBoundedLogClearAndLateCompletionDoNotRestoreEntries() {
        let log = NetworkLog(capacity: 2)
        let first = log.begin(.models, request: nil)
        let second = log.begin(.token, request: nil)
        _ = log.begin(.keys, request: nil)
        XCTAssertEqual(log.entries.count, 2)
        log.finish(first)
        XCTAssertFalse(log.entries.contains { $0.id == first })
        log.clear()
        log.finish(second, error: ChatError.timeout)
        XCTAssertTrue(log.entries.isEmpty)
    }
}

private final class NetworkLogFixture: URLProtocol {
    static var status = 200
    static var body = Data()
    static var error: URLError?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let error = Self.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Set-Cookie": "COOKIE_SECRET"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
