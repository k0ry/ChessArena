import Foundation

public enum RequestTimeouts {
    public static let player: TimeInterval = 10 * 60
}

public enum ModelCatalog {
    /// docs.x.ai models, October 2026: Grok 4.7 is the chat model.
    public static let grokModel = "grok-4.7"
    public static let grokAPI = URL(string: "https://api.x.ai/v1")!
    /// developers.openai.com model `chat-latest`: the Instant model used in ChatGPT.
    /// Chat Completions `v1/chat/completions` is supported.
    public static let chatGPTModel = "chat-latest"
    public static let openAIAPI = URL(string: "https://api.openai.com/v1")!
    public static let toneTest = "Sound check. The pieces are awake, and so is the sarcasm."
}

public struct Seat: Equatable, Sendable {
    public var name: String
    public var baseURL: URL
    public var model: String
    public var apiKey: String
    public var side: Side

    public init(name: String, baseURL: URL, model: String, apiKey: String, side: Side) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.side = side
    }

    public static func defaultWhite(apiKey: String) -> Seat {
        Seat(name: "Grok", baseURL: ModelCatalog.grokAPI, model: ModelCatalog.grokModel, apiKey: apiKey, side: .white)
    }

    public static func defaultBlack(apiKey: String) -> Seat {
        Seat(name: "ChatGPT", baseURL: ModelCatalog.openAIAPI, model: ModelCatalog.chatGPTModel, apiKey: apiKey, side: .black)
    }

    public var completionsURL: URL {
        baseURL.appendingPathComponent("chat").appendingPathComponent("completions")
    }
}

public struct ChatCall: Equatable, Sendable {
    public var url: URL
    public var apiKey: String
    public var model: String
    public var system: String
    public var user: String

    public init(url: URL, apiKey: String, model: String, system: String, user: String) {
        self.url = url
        self.apiKey = apiKey
        self.model = model
        self.system = system
        self.user = user
    }
}

public enum ChatError: Error, Equatable {
    case transport
    case timeout
    case http(status: Int, reason: APIErrorReason)
    case unreadable

    public var userMessage: String {
        switch self {
        case .transport: return "Не удалось соединиться с API. Проверьте сеть и повторите ход."
        case .timeout: return "API не ответил за отведённое время. Повторите ход."
        case .unreadable: return "API вернул нечитаемый ответ."
        case .http(let status, let reason):
            return "HTTP \(status): \(reason.userMessage)"
        }
    }
}

/// Only known categories cross into the UI. Provider messages can contain credentials.
public enum APIErrorReason: String, Equatable {
    case authentication, modelAccess, quota, rateLimit, region, permission, server, request

    public var userMessage: String {
        switch self {
        case .authentication: return "API отклонил ключ. Проверьте ключ этой стороны."
        case .modelAccess: return "Модель не найдена или недоступна этому ключу. Проверьте имя модели и доступ."
        case .quota: return "Исчерпана квота или лимит расходов API. Проверьте лимиты проекта у провайдера."
        case .rateLimit: return "Превышен лимит запросов. Подождите и повторите ход."
        case .region: return "API недоступен из текущего региона."
        case .permission: return "API запретил доступ. Проверьте разрешения проекта и ключа."
        case .server: return "Ошибка сервера провайдера. Повторите ход позже."
        case .request: return "API отклонил запрос. Проверьте модель и её совместимость с Chat Completions."
        }
    }

    static func classify(status: Int, data: Data) -> Self {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = error?["code"] as? String ?? ""
        let type = error?["type"] as? String ?? ""
        if code == "invalid_api_key" || status == 401 { return .authentication }
        if code == "model_not_found" { return .modelAccess }
        if code == "unsupported_country_region_territory" { return .region }
        let quotaCodes = ["insufficient_quota", "billing_hard_limit_reached", "billing_not_active", "usage_limit_reached", "organization_usage_limit_exceeded", "project_usage_limit_exceeded"]
        if quotaCodes.contains(code) || type == "insufficient_quota" { return .quota }
        if status == 429 { return .rateLimit }
        if status == 403 { return .permission }
        if status == 404 { return .modelAccess }
        if status >= 500 { return .server }
        return .request
    }
}

public protocol ChatTransport: AnyObject {
    func requestURL(for call: ChatCall) -> URL
    func complete(_ call: ChatCall) async throws -> String
}

public extension ChatTransport {
    func requestURL(for call: ChatCall) -> URL { call.url }
}

public enum ChatParser {
    public static func messageContent(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content
    }

    public static func moveIntent(from content: String) -> (move: String, taunt: String)? {
        guard let object = jsonObject(in: content),
              let move = object["move"] as? String else {
            return nil
        }
        let taunt = (object["taunt"] as? String) ?? ""
        return (move, taunt)
    }

    private static func jsonObject(in content: String) -> [String: Any]? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
            text = text.replacingOccurrences(of: "```", with: "")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return nil
        }
        let slice = Data(text[start...end].utf8)
        return try? JSONSerialization.jsonObject(with: slice) as? [String: Any]
    }
}

public enum Prompts {
    public static func player(
        side: Side,
        fen: String,
        legal: [String],
        history: [String],
        rejection: String?
    ) -> (system: String, user: String) {
        let system = """
        You are \(side == .white ? "White" : "Black") in a chess broadcast. Play as a professional chess player whose priority is the strongest practical result: win when possible and defend resourcefully when worse.
        Use the supplied FEN as the authoritative current position and the move history to understand the game. Build a coherent plan for the coming moves rather than choosing an isolated attractive move.
        Before choosing, identify the opponent's immediate threats, checks, captures and mating ideas. Compare promising candidate moves by calculating several moves ahead, considering the opponent's strongest legal replies rather than assuming mistakes. Verify imagined continuations against the resulting positions.
        Balance concrete tactics with king safety, material, piece activity, development, central control, pawn structure and endgame prospects. Adapt your plan as the position changes. Before committing, check that your move does not allow an avoidable mate, lose material without sufficient compensation or miss a stronger forcing continuation.
        Choose exactly one move from the supplied Legal UCI list. This list applies to the current position only. If an attempt was rejected, correct it using the current FEN and legal moves.
        Keep your analysis private. The short taunt is for the broadcast and must not replace careful move selection. Reply with JSON only, without markdown or analysis: {"move":"<uci>","taunt":"<one short dry English sentence>"}.
        """
        var user = "FEN: \(fen)\nLegal UCI: \(legal.joined(separator: " "))\nHistory: \(history.joined(separator: " "))"
        if let rejection {
            user += "\nThe previous attempt was illegal. \(rejection) Choose a legal UCI."
        }
        return (system, user)
    }

    public static func moveCommentary(fen: String, san: String) -> (system: String, user: String) {
        (
            "You are the host of a chess broadcast. Speak one or two dry humorous English sentences about the move already on the board. Do not suggest a future move.",
            "FEN after the move: \(fen)\nMove played: \(san)"
        )
    }

    public static func waiting(side: Side) -> (system: String, user: String) {
        (
            "You are the host of a chess broadcast. One short dry English sentence about the wait. Do not name a move.",
            "\(side == .white ? "White" : "Black") is still thinking."
        )
    }

    public static func resignation(side: Side) -> (system: String, user: String) {
        (
            "You are the host of a chess broadcast. One short English sentence.",
            "\(side == .white ? "White" : "Black") resigns."
        )
    }

    public static func stall(side: Side) -> (system: String, user: String) {
        (
            "You are the host of a chess broadcast. One short English sentence.",
            "\(side == .white ? "White" : "Black") has stalled and the match is paused."
        )
    }

    public static func chronicle(moves: [String], previous: [String]) -> (system: String, user: String) {
        (
            "You are the host of a chess broadcast. Summarize the whole game from move one in at most 35 dry humorous English words. Do not repeat earlier jokes.",
            "Moves from the start: \(moves.joined(separator: " "))\nDo not repeat: \(previous.joined(separator: " | "))"
        )
    }

    public static func final(title: String, moves: [String]) -> (system: String, user: String) {
        (
            "You are the host of a chess broadcast. Two dry humorous English sentences on the finished game.",
            "Result: \(title)\nMoves: \(moves.joined(separator: " "))"
        )
    }
}

public final class URLSessionChatTransport: ChatTransport {
    public var session: URLSession
    public var timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = RequestTimeouts.player) {
        self.session = session
        self.timeout = timeout
    }

    public func complete(_ call: ChatCall) async throws -> String {
        var request = URLRequest(url: call.url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(call.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": call.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": call.system],
                ["role": "user", "content": call.user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw ChatError.timeout
        } catch {
            throw ChatError.transport
        }
        guard let http = response as? HTTPURLResponse else {
            throw ChatError.transport
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ChatError.http(status: http.statusCode, reason: APIErrorReason.classify(status: http.statusCode, data: data))
        }
        guard let content = ChatParser.messageContent(from: data) else {
            throw ChatError.unreadable
        }
        return content
    }
}

public final class ScriptedChat: ChatTransport {
    private struct Pending {
        var call: ChatCall
        var continuation: CheckedContinuation<String, Error>
    }

    public private(set) var calls: [ChatCall] = []
    private var pending: [Pending] = []
    public var onWaiting: (() -> Void)?

    public init() {}

    public func complete(_ call: ChatCall) async throws -> String {
        calls.append(call)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(call: call, continuation: continuation))
            onWaiting?()
        }
    }

    public func fulfill(where predicate: (ChatCall) -> Bool, body: String) {
        guard let index = pending.firstIndex(where: { predicate($0.call) }) else { return }
        let item = pending.remove(at: index)
        item.continuation.resume(returning: body)
    }

    public func fail(where predicate: (ChatCall) -> Bool, error: ChatError = .transport) {
        guard let index = pending.firstIndex(where: { predicate($0.call) }) else { return }
        let item = pending.remove(at: index)
        item.continuation.resume(throwing: error)
    }
}
