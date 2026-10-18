import Combine
import Foundation

public enum NetworkOperation: String, Sendable {
    case lc0Move = "LC0 · локальный поиск хода"
    case chat = "Запрос к модели"
    case deepSeekChat = "DeepSeek · запрос к модели"
    case deepSeekModels = "DeepSeek · каталог моделей"
    case responses = "ChatGPT · поток ответа"
    case models = "ChatGPT · каталог моделей"
    case token = "ChatGPT · обмен / обновление сессии"
    case discovery = "ChatGPT · параметры авторизации"
    case keys = "ChatGPT · проверка подписи"
    case speechAPI = "OpenAI · озвучка по API-ключу"
    case localSpeech = "Qwen · локальная озвучка MLX"
    case speech = "ChatGPT · проверка озвучки"
    case cliVersion = "Gemini CLI · версия"
    case cliModels = "Gemini CLI · каталог моделей"
    case cliCompletion = "Gemini CLI · запрос к модели"
    case anthropicMessages = "Claude · запрос к модели"
    case anthropicModels = "Claude · каталог моделей"
    case claudeVersion = "Claude Code CLI · версия"
    case claudeVerify = "Claude Code CLI · проверка подключения"
    case claudeCompletion = "Claude Code CLI · запрос к модели"

    var isClaudeCLI: Bool { [.claudeVersion, .claudeVerify, .claudeCompletion].contains(self) }
}

public struct NetworkLogEntry: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case pending = "Ожидание", success = "Успешно", failed = "Ошибка", cancelled = "Отменён" }
    public let id: UUID
    public let date: Date
    public let operation: NetworkOperation
    public let endpoint: String
    public let method: String
    public let timeout: TimeInterval?
    public let sentBytes: Int?
    public var status: Status = .pending
    public var httpStatus: Int?
    public var exitCode: Int32?
    public var receivedBytes: Int?
    public var headersAfter: TimeInterval?
    public var duration: TimeInterval?
    public var error: String?
    public var isCLI: Bool { method == "CLI" }
    public var text: String {
        var lines = [date.formatted(date: .numeric, time: .standard), operation.rawValue,
                     "ID: \(id.uuidString)", "\(method) \(endpoint)", "Статус: \(status.rawValue)"]
        if let httpStatus { lines.append("HTTP: \(httpStatus)") }
        if let exitCode { lines.append("Код завершения CLI: \(exitCode)") }
        if let timeout { lines.append(String(format: "Тайм-аут: %.0f с", timeout)) }
        if let headersAfter { lines.append(String(format: "До заголовков ответа: %.2f с", headersAfter)) }
        if let duration { lines.append(String(format: "Длительность: %.2f с", duration)) }
        if let sentBytes { lines.append("Тело запроса: \(sentBytes) байт") }
        if let receivedBytes { lines.append("Данные ответа: \(receivedBytes) байт") }
        if let error { lines.append("Ошибка: \(error)") }
        if isCLI { lines.append("Локальный процесс CLI. Внутренние HTTP-запросы CLI недоступны приложению.") }
        if operation == .responses { lines.append("Размер ответа учитывает прочитанный текст SSE без разделителей строк.") }
        return lines.joined(separator: "\n")
    }
}

/// Metadata only: never retain bodies, headers, OAuth values, raw errors or CLI arguments/output.
@MainActor
public final class NetworkLog: ObservableObject {
    public static let shared = NetworkLog()
    @Published public private(set) var entries: [NetworkLogEntry] = []
    public let capacity: Int
    public init(capacity: Int = 500) { self.capacity = max(1, capacity) }

    func begin(_ operation: NetworkOperation, request: URLRequest?) -> UUID {
        let id = UUID()
        let method = request.map { ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"].contains($0.httpMethod ?? "GET") ? ($0.httpMethod ?? "GET") : "HTTP" } ?? "CLI"
        entries.insert(NetworkLogEntry(id: id, date: Date(), operation: operation,
            endpoint: request.map { Self.endpoint($0.url) } ?? (operation == .lc0Move ? "local-uci://lc0" : operation.isClaudeCLI ? "local-cli://claude" : "local-cli://antigravity"),
            method: method, timeout: request?.timeoutInterval, sentBytes: request?.httpBody?.count), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        return id
    }

    // Known endpoints are enough to diagnose this client's routes. Unknown paths can contain secrets.
    private static func endpoint(_ url: URL?) -> String {
        guard let url else { return "(адрес отсутствует)" }
        let hosts = ["api.x.ai", "api.openai.com", "auth.openai.com", "api.anthropic.com", "api.deepseek.com"]
        let paths = ["/v1/chat/completions", "/v1/responses", "/v1/models", "/v1/messages", "/v1/audio/speech",
                     "/api/accounts/oauth/token", "/.well-known/openid-configuration", "/.well-known/jwks.json", "/chat/completions", "/models"]
        let host = hosts.contains(url.host ?? "") ? url.host! : "[сервер скрыт]"
        let path = paths.contains(url.path) ? url.path : "/[путь скрыт]"
        return (url.scheme == "https" ? "https://" : "http://") + host + path
    }

    func response(_ id: UUID, response: URLResponse, bytes: Int?) {
        update(id) {
            $0.httpStatus = (response as? HTTPURLResponse)?.statusCode
            if bytes == nil { $0.headersAfter = max(0, Date().timeIntervalSince($0.date)) }
            $0.receivedBytes = bytes
        }
    }
    func payload(_ id: UUID, bytes: Int, exitCode: Int32? = nil) {
        update(id) { $0.receivedBytes = bytes; $0.exitCode = exitCode }
    }
    func finish(_ id: UUID, error: Error? = nil) {
        update(id) {
            $0.duration = max(0, Date().timeIntervalSince($0.date))
            if let error {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                $0.status = cancelled ? .cancelled : .failed
                if cancelled { $0.error = "Операция отменена." }
                else if let error = error as? SpeechFailure { $0.error = error.message }
                else if let error = error as? ChatError { $0.error = error.userMessage }
                else if let error = error as? URLError { $0.error = Self.networkError(error.code) }
                else if error is DecodingError || (error as NSError).domain == NSCocoaErrorDomain {
                    $0.error = "Не удалось обработать данные ответа или локальные файлы."
                } else { $0.error = "Операция не завершена. Подробности подключения — в окне управления." }
            } else { $0.status = .success }
        }
    }
    private static func networkError(_ code: URLError.Code) -> String {
        let message: String
        switch code {
        case .timedOut: message = "Превышено время ожидания"
        case .notConnectedToInternet: message = "Нет подключения к интернету"
        case .cannotFindHost, .dnsLookupFailed: message = "Не удалось найти сервер (DNS)"
        case .cannotConnectToHost: message = "Не удалось установить соединение с сервером"
        case .networkConnectionLost: message = "Соединение разорвано"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: message = "Ошибка TLS / сертификата сервера"
        default: message = "Ошибка сети"
        }
        return "\(message) · NSURLErrorDomain \(code.rawValue)."
    }
    private func update(_ id: UUID, mutation: (inout NetworkLogEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].status == .pending else { return }
        var entry = entries[index]
        mutation(&entry)
        entries[index] = entry
    }
    public func clear() { entries.removeAll() }
}

struct NetworkTrace: Sendable {
    let id: UUID
    let log: NetworkLog
    static func track<T>(_ operation: NetworkOperation, request: URLRequest? = nil,
                         log: NetworkLog? = nil, work: (NetworkTrace) async throws -> T) async throws -> T {
        let destination: NetworkLog
        if let log { destination = log } else { destination = await NetworkLog.shared }
        let log = destination
        let trace = await NetworkTrace(id: log.begin(operation, request: request), log: log)
        do {
            let result = try await work(trace)
            await log.finish(trace.id)
            return result
        } catch {
            await log.finish(trace.id, error: error)
            throw error
        }
    }
    func response(_ response: URLResponse, bytes: Int? = nil) async { await log.response(id, response: response, bytes: bytes) }
    func payload(bytes: Int, exitCode: Int32? = nil) async { await log.payload(id, bytes: bytes, exitCode: exitCode) }
}

extension URLSession {
    /// The caller still owns response validation; non-2xx responses are logged without changing behavior.
    func loggedData(for request: URLRequest, operation: NetworkOperation) async throws -> (Data, URLResponse) {
        try await NetworkTrace.track(operation, request: request) { trace in
            let (data, response) = try await self.data(for: request)
            await trace.response(response, bytes: data.count)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                await trace.log.finish(trace.id, error: ChatError.http(status: http.statusCode,
                    reason: APIErrorReason.classify(status: http.statusCode, data: data)))
            }
            return (data, response)
        }
    }
}
