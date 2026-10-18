import AppKit
import CryptoKit
import Foundation
import Network
import Security

public enum ConnectionError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct ChatGPTModel: Identifiable, Equatable {
    public var id: String
    public var name: String
}

struct OAuthAttempt {
    let state: String
    let nonce: String
    let verifier: String
    let redirect: String
    let clientID: String

    func authorizationURL(hostID: String) -> URL {
        var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        var params = ["client_id": clientID, "ext_agent_host_id": hostID,
                      "response_type": "code", "redirect_uri": redirect,
                      "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                      "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce,
                      "code_challenge_method": "S256", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL]
        if clientID == "dynamic_agent_client" { params["agent_name_hint"] = "ChessArena" }
        url.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    func callback(_ url: URL) throws -> (code: String, client: String) {
        guard url.scheme == "http", url.host == "127.0.0.1", url.path == "/auth/callback",
              url.port == URL(string: redirect)?.port,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw ConnectionError.message("Некорректный адрес возврата авторизации.")
        }
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil else { throw ConnectionError.message("Некорректный ответ авторизации.") }
            values[item.name] = item.value ?? ""
        }
        guard values["state"] == state else { throw ConnectionError.message("Проверка безопасности входа не прошла. Повторите вход.") }
        if values["error"] != nil { throw ConnectionError.message("Вход отменён или доступ не разрешён.") }
        let client = values["client_id"] ?? clientID
        guard client != "dynamic_agent_client", !client.isEmpty,
              clientID == "dynamic_agent_client" || client == clientID,
              let code = values["code"], !code.isEmpty else {
            throw ConnectionError.message("Регистрация ChatGPT не завершена. Повторите вход.")
        }
        return (code, client)
    }
}

private struct OAuthSession: Codable {
    var clientID: String
    var subject: String
    var email: String
    var accessToken: String
    var refreshToken: String
    var scopes: String
    var expiresAt: Date
}

@MainActor
public final class ChatGPTConnection: ObservableObject {
    @Published public private(set) var status = "Войдите, чтобы подключить чёрных"
    @Published public private(set) var connected = false
    @Published public private(set) var busy = false
    @Published public private(set) var models: [ChatGPTModel] = []
    private let secrets = KeychainSecretStore(service: "com.chessarena.oauth")
    private var session: OAuthSession?
    private var listener: NWListener?
    private var attempt: OAuthAttempt?
    private var expiryTask: Task<Void, Never>?
    private var refreshTask: Task<OAuthSession, Error>?
    private let network: URLSession
    private var hostID: String {
        let key = "ChessArena.oauth.hostID"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    public init(network: URLSession = .shared) { self.network = network }

    public func restore() async {
        guard !busy else { return }
        do {
            if let saved = try secrets.load(account: "session") {
                session = try JSONDecoder().decode(OAuthSession.self, from: Data(saved.utf8))
                busy = true
                defer { busy = false }
                try await loadModels()
            }
        } catch { status = safeMessage(error); connected = false }
    }

    public func signIn() {
        guard !busy else { return }
        busy = true
        status = "Открываю вход в ChatGPT…"
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Self.receive(connection, data: Data()) { url in
                    Task { @MainActor in await self?.accept(url) }
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else { return }
                        let attempt = OAuthAttempt(state: Self.random(), nonce: Self.random(), verifier: Self.random(),
                            redirect: "http://127.0.0.1:\(port.rawValue)/auth/callback", clientID: self.session?.clientID ?? "dynamic_agent_client")
                        self.attempt = attempt
                        if !NSWorkspace.shared.open(attempt.authorizationURL(hostID: self.hostID)) {
                            self.cancelSignIn(); self.status = "Не удалось открыть браузер. Повторите вход."
                        } else { self.status = "Завершите вход и разрешите использование плана в браузере" }
                    case .failed:
                        self.cancelSignIn(); self.status = "Не удалось открыть локальный адрес возврата. Повторите вход."
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
                self?.cancelSignIn()
                self?.status = "Время входа истекло. Нажмите Continue with ChatGPT ещё раз."
            }
        } catch { cancelSignIn(); status = safeMessage(error) }
    }

    public func cancelSignIn() {
        listener?.stateUpdateHandler = nil
        listener?.cancel(); listener = nil; attempt = nil
        expiryTask?.cancel(); expiryTask = nil; busy = false
    }

    private func accept(_ url: URL) async {
        guard let attempt else { return }
        do {
            let callback = try attempt.callback(url)
            self.attempt = nil
            listener?.cancel(); listener = nil
            expiryTask?.cancel(); expiryTask = nil
            status = "Проверяю авторизацию…"
            let response = try await tokenRequest([
                "grant_type": "authorization_code", "client_id": callback.client, "code": callback.code,
                "code_verifier": attempt.verifier, "redirect_uri": attempt.redirect,
                "resource": "https://api.openai.com/v1"
            ])
            guard let idToken = response["id_token"] as? String else { throw ConnectionError.message("ChatGPT не вернул подтверждение личности.") }
            let identity = try await verifyIDToken(idToken, client: callback.client, nonce: attempt.nonce)
            if let old = session, old.clientID == callback.client, old.subject != identity.subject {
                throw ConnectionError.message("Этот вход относится к другому аккаунту.")
            }
            let newSession = try makeSession(response, client: callback.client, subject: identity.subject, email: identity.email)
            try save(newSession)
            session = newSession
            try await loadModels()
        } catch { status = safeMessage(error); connected = false }
        cancelSignIn()
    }

    /// Whether the subscription token answers the speech endpoint. Undocumented for this sign-in; only a live request tells.
    @Published public private(set) var speechSupported: Bool?
    @Published public private(set) var speechStatus = "Озвучка по подписке не проверена."

    public func checkSpeech() {
        guard !busy else { return }
        busy = true
        speechStatus = "Проверяю озвучку по подписке…"
        Task {
            defer { busy = false }
            do {
                let token = try await accessToken()
                var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 30
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": "gpt-4o-mini-tts", "input": "Sound check.", "voice": "onyx", "response_format": "pcm",
                ])
                let (data, response) = try await NetworkTrace.track(.speech, request: request) { trace in
                    let (data, response) = try await network.data(for: request)
                    await trace.response(response, bytes: data.count)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw SpeechFailure.http(http, data: data, subscription: true, secret: token)
                    }
                    return (data, response)
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status), data.count > 2_000 {
                    speechSupported = true
                    speechStatus = "Озвучка по подписке отвечает (HTTP \(status), \(data.count) байт звука)."
                } else {
                    speechSupported = false
                    let reason = APIErrorReason.classify(status: status, data: data)
                    speechStatus = "Озвучка по подписке недоступна: HTTP \(status), \(reason.userMessage) Остаётся системный голос."
                }
            } catch {
                speechSupported = false
                speechStatus = "Озвучка по подписке: \(error is SpeechFailure || error is URLError ? SpeechFailure.describe(error) : safeMessage(error)) Остаётся системный голос."
            }
        }
    }

    public func accessToken() async throws -> String {
        guard let saved = session else { throw ConnectionError.message("Сначала войдите в ChatGPT.") }
        guard saved.scopes.split(separator: " ").contains("chatgpt.tokens.use.direct") else {
            throw ConnectionError.message("При входе разрешите использование плана ChatGPT.")
        }
        if saved.expiresAt.timeIntervalSinceNow > 60 { return saved.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { @MainActor in
            let response = try await self.tokenRequest(["grant_type": "refresh_token", "client_id": saved.clientID,
                "refresh_token": saved.refreshToken, "resource": "https://api.openai.com/v1"])
            var responseWithDefaults = response
            if response["refresh_token"] == nil { responseWithDefaults["refresh_token"] = saved.refreshToken }
            if response["scope"] == nil { responseWithDefaults["scope"] = saved.scopes }
            let renewed = try self.makeSession(responseWithDefaults, client: saved.clientID, subject: saved.subject, email: saved.email)
            try self.save(renewed)
            self.session = renewed
            return renewed
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    private func loadModels() async throws {
        let token = try await accessToken()
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await network.loggedData(for: request, operation: .models)
        try Self.check(response, data: data)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        models = (body?["models"] as? [[String: Any]] ?? []).compactMap {
            guard $0["visibility"] as? String == "list", let id = $0["slug"] as? String else { return nil }
            return ChatGPTModel(id: id, name: $0["display_name"] as? String ?? id)
        }
        guard !models.isEmpty else { throw ConnectionError.message("Аккаунт не вернул доступных моделей. Проверьте разрешение использовать план ChatGPT.") }
        connected = true
        status = "Подключено · \(session?.email ?? "ChatGPT")"
    }

    private func tokenRequest(_ values: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthEncoding.form(values)
        let (data, response) = try await network.loggedData(for: request, operation: .token)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectionError.message("ChatGPT не подтвердил сессию. Повторите вход.")
        }
        return object
    }

    private func makeSession(_ object: [String: Any], client: String, subject: String, email: String) throws -> OAuthSession {
        guard let access = object["access_token"] as? String, !access.isEmpty,
              let refresh = object["refresh_token"] as? String, !refresh.isEmpty,
              let scope = object["scope"] as? String, scope.split(separator: " ").contains("chatgpt.tokens.use.direct"),
              let expiry = object["expires_in"] as? Double, expiry > 0,
              (object["token_type"] as? String)?.lowercased() == "bearer" else {
            throw ConnectionError.message("Вход не разрешил использование плана ChatGPT. Повторите вход и включите это разрешение.")
        }
        return OAuthSession(clientID: client, subject: subject, email: email, accessToken: access,
                            refreshToken: refresh, scopes: scope, expiresAt: Date().addingTimeInterval(expiry))
    }

    private func save(_ value: OAuthSession) throws {
        try secrets.save(account: "session", secret: String(decoding: JSONEncoder().encode(value), as: UTF8.self))
    }

    func verifyIDToken(_ token: String, client: String, nonce: String) async throws -> (subject: String, email: String) {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let headerData = Data(base64URL: parts[0]), let payloadData = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String else {
            throw ConnectionError.message("Некорректное подтверждение личности ChatGPT.")
        }
        let (discoveryData, discoveryResponse) = try await network.loggedData(for: URLRequest(url: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!), operation: .discovery)
        try Self.check(discoveryResponse, data: discoveryData)
        let discovery = try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any]
        guard let jwks = discovery?["jwks_uri"] as? String, let url = URL(string: jwks),
              url.scheme == "https", url.host == "auth.openai.com" else { throw ConnectionError.message("Не удалось проверить издателя входа.") }
        let (data, response) = try await network.loggedData(for: URLRequest(url: url), operation: .keys)
        try Self.check(response, data: data)
        let keys = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["keys"] as? [[String: Any]] ?? []
        guard let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              let n = key["n"] as? String, let e = key["e"] as? String,
              let modulus = Data(base64URL: n), !modulus.isEmpty, let exponent = Data(base64URL: e), !exponent.isEmpty,
              let publicKey = SecKeyCreateWithData(OAuthEncoding.rsa(modulus: modulus, exponent: exponent) as CFData,
                [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil) else {
            throw ConnectionError.message("Подпись входа ChatGPT не прошла проверку.")
        }
        let audience = (payload["aud"] as? [String]) ?? [payload["aud"] as? String ?? ""]
        guard payload["iss"] as? String == "https://auth.openai.com", audience.contains(client),
              audience.count == 1 || payload["azp"] as? String == client,
              let exp = payload["exp"] as? Double, exp > Date().timeIntervalSince1970,
              payload["nonce"] as? String == nonce, let sub = payload["sub"] as? String, !sub.isEmpty else {
            throw ConnectionError.message("Подтверждение входа истекло или относится к другому приложению.")
        }
        return (sub, payload["email"] as? String ?? "ChatGPT")
    }

    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ChatError.transport }
        guard (200..<300).contains(http.statusCode) else {
            throw ChatError.http(status: http.statusCode, reason: APIErrorReason.classify(status: http.statusCode, data: data))
        }
    }

    private func safeMessage(_ error: Error) -> String {
        if let error = error as? ChatError { return error.userMessage }
        if let error = error as? ConnectionError { return error.localizedDescription }
        return "Не удалось подключиться к ChatGPT. Проверьте сеть и повторите вход."
    }

    private static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // UUID also uses the operating system's random source.
            return UUID().uuidString + UUID().uuidString
        }
        return Data(bytes).base64URL
    }

    nonisolated private static func receive(_ connection: NWConnection, data: Data, completion: @escaping (URL) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, done, error in
            var accumulated = data
            if let chunk { accumulated.append(chunk) }
            guard accumulated.count <= 16384, error == nil else { connection.cancel(); return }
            if let request = String(data: accumulated, encoding: .utf8), request.contains("\r\n\r\n") {
                let line = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                guard line.count == 3, line[0] == "GET", line[1].hasPrefix("/auth/callback?"),
                      case .hostPort(_, let port) = connection.currentPath?.localEndpoint,
                      let url = URL(string: "http://127.0.0.1:\(port.rawValue)" + line[1]) else { connection.cancel(); return }
                let body = "<!doctype html><html><body style='background:#101827;color:white;font:24px system-ui;padding:80px'>ChessArena<br><p>Return to ChessArena to see your connection status.</p></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                completion(url)
            } else if !done { receive(connection, data: accumulated, completion: completion) }
            else { connection.cancel() }
        }
    }
}

enum OAuthEncoding {
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    static func rsa(modulus: Data, exponent: Data) -> Data {
        func tlv(_ tag: UInt8, _ data: Data) -> Data {
            var length = data.count
            var size = [UInt8]()
            repeat { size.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
            return Data([tag] + (data.count < 128 ? [UInt8(data.count)] : [0x80 | UInt8(size.count)] + size)) + data
        }
        func integer(_ data: Data) -> Data { tlv(2, (data.first! & 0x80 != 0 ? Data([0]) : Data()) + data) }
        return tlv(0x30, integer(modulus) + integer(exponent))
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        let value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
}
