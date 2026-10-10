import XCTest
import SceneKit
import Security
@testable import ChessArenaCore

final class ConnectionTests: XCTestCase {
    func testPKCEAndAuthorizationParameters() throws {
        let attempt = OAuthAttempt(state: "state", nonce: "nonce", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
                                   redirect: "http://127.0.0.1:1455/auth/callback", clientID: "dynamic_agent_client")
        let url = attempt.authorizationURL(hostID: "urn:uuid:test")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let params = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(params["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(params["agent_name_hint"], "ChessArena")
        XCTAssertTrue(params["scope"]!.contains("chatgpt.tokens.use.direct"))
        XCTAssertEqual(params["resource"], "https://api.openai.com/v1")
        XCTAssertNil(params["client_secret"])
    }

    func testCallbackBindsStateClientAndLoopback() throws {
        let fresh = OAuthAttempt(state: "expected", nonce: "n", verifier: "v", redirect: "http://127.0.0.1:1455/auth/callback", clientID: "dynamic_agent_client")
        let prefix = "http://127.0.0.1:1455/auth/callback?"
        XCTAssertEqual(try fresh.callback(URL(string: prefix + "state=expected&code=code&client_id=oaiapp_test")!).client, "oaiapp_test")
        for query in ["state=wrong&code=code&client_id=oaiapp_test", "state=expected&code=code", "state=expected&error=access_denied", "state=expected&state=expected&code=code&client_id=oaiapp_test"] {
            XCTAssertThrowsError(try fresh.callback(URL(string: prefix + query)!))
        }
        XCTAssertThrowsError(try fresh.callback(URL(string: "http://example.com:1455/auth/callback?state=expected&code=code&client_id=oaiapp_test")!))
        let returning = OAuthAttempt(state: "expected", nonce: "n", verifier: "v", redirect: fresh.redirect, clientID: "oaiapp_original")
        XCTAssertEqual(try returning.callback(URL(string: prefix + "state=expected&code=code")!).client, "oaiapp_original")
        XCTAssertThrowsError(try returning.callback(URL(string: prefix + "state=expected&code=code&client_id=oaiapp_other")!))
        XCTAssertEqual(String(decoding: OAuthEncoding.form(["code": "a+b &x"]), as: UTF8.self), "code=a%2Bb%20%26x")
    }

    func testResponsesRequireCompletedEventAndRejectFailures() throws {
        var stream = ResponsesStream()
        XCTAssertNil(try stream.consume("event: response.output_text.delta"))
        XCTAssertNil(try stream.consume(#"data: {"type":"response.output_text.delta","delta":"e7e5"}"#))
        XCTAssertNil(try stream.consume("data: [DONE]"))
        XCTAssertEqual(try stream.consume(#"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"#), "e7e5")
        var failed = ResponsesStream()
        XCTAssertThrowsError(try failed.consume(#"data: {"type":"response.failed","response":{"error":{"code":"insufficient_quota","message":"private-key"}}}"#)) { error in
            XCTAssertEqual(error as? ChatError, .http(status: 400, reason: .quota))
            XCTAssertFalse(String(describing: error).contains("private-key"))
        }
        XCTAssertThrowsError(try failed.consume(#"data: {"type":"response.incomplete"}"#))
    }

    func testSceneRemovesCapturesAndMovesCastlingRook() {
        func play(_ moves: [String]) -> BoardScene {
            let scene = BoardScene()
            var position = Position.standard()
            for uci in moves {
                let move = position.parseUCI(uci)!
                XCTAssertTrue(position.isLegal(move))
                let side = position.sideToMove
                position = position.applying(move)
                scene.animate(move: move, positionAfter: position, side: side, duration: 0)
            }
            return scene
        }
        let capture = play(["e2e4", "d7d5", "e4d5"])
        let pieces = capture.scene.rootNode.childNodes.filter { $0.name?.hasPrefix("piece-") == true }
        XCTAssertEqual(pieces.count, 31)
        XCTAssertEqual(pieces.filter { $0.name == "piece-pawn-d5" }.count, 1)
        let castle = play(["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "e1g1"])
        XCTAssertNil(castle.node(named: "piece-rook-h1"))
        XCTAssertNotNil(castle.node(named: "piece-rook-f1"))
        XCTAssertNotNil(castle.node(named: "piece-king-g1"))
        let ep = play(["e2e4", "a7a6", "e4e5", "d7d5", "e5d6"])
        XCTAssertNil(ep.node(named: "piece-pawn-d5"))
        XCTAssertNotNil(ep.node(named: "piece-pawn-d6"))
    }
}

private final class IdentityFixtureProtocol: URLProtocol {
    static var keys = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let discovery = Data(#"{"jwks_uri":"https://auth.openai.com/test-keys"}"#.utf8)
        let data = request.url!.path.contains("openid-configuration") ? Self.keys.isEmpty ? Data() : discovery : Self.keys
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension ConnectionTests {
    @MainActor
    func testIDTokenSignatureAndClaimsAreValidated() async throws {
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let der = [UInt8](try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data)
        var offset = 0
        func length() -> Int {
            let first = Int(der[offset]); offset += 1
            if first < 128 { return first }
            var value = 0
            for _ in 0..<(first & 127) { value = (value << 8) | Int(der[offset]); offset += 1 }
            return value
        }
        offset += 1; _ = length()
        func integer() -> Data {
            offset += 1
            let count = length()
            let result = Data(der[offset..<(offset + count)]); offset += count
            return result.first == 0 ? result.dropFirst() : result
        }
        let n = integer(), e = integer()
        IdentityFixtureProtocol.keys = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "test", "n": n.base64URL, "e": e.base64URL]]])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IdentityFixtureProtocol.self]
        let connection = ChatGPTConnection(network: URLSession(configuration: config))
        func token(nonce: String = "expected", audience: String = "oaiapp_test", expired: Bool = false) throws -> String {
            let header = Data(#"{"alg":"RS256","kid":"test"}"#.utf8).base64URL
            let body = try JSONSerialization.data(withJSONObject: ["iss": "https://auth.openai.com", "aud": audience,
                "sub": "test-user", "email": "test@example.com", "nonce": nonce,
                "exp": Date().addingTimeInterval(expired ? -60 : 600).timeIntervalSince1970]).base64URL
            let signed = header + "." + body
            let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, nil)) as Data
            return signed + "." + signature.base64URL
        }
        let valid = try token()
        let identity = try await connection.verifyIDToken(valid, client: "oaiapp_test", nonce: "expected")
        XCTAssertEqual(identity.subject, "test-user")
        for invalid in [try token(nonce: "wrong"), try token(audience: "other"), try token(expired: true), valid + "tampered"] {
            do {
                _ = try await connection.verifyIDToken(invalid, client: "oaiapp_test", nonce: "expected")
                XCTFail("Untrusted identity accepted")
            } catch { XCTAssertTrue(error is ConnectionError) }
        }
    }
}
