import Combine
import Foundation

public struct ModelLogEntry: Identifiable, Equatable {
    public enum Status: String { case pending = "Ожидание", received = "Ответ", failed = "Ошибка", cancelled = "Отменён" }
    public let id: UUID
    public let date: Date
    public var context: String
    public var model: String
    public var endpoint: String
    public var system: String
    public var user: String
    public var selfNotes: String? = nil
    public var gameAdvice: String? = nil
    public var response: String?
    public var error: String?
    public var status: Status = .pending
    public var duration: TimeInterval?

    public var text: String {
        var parts = ["\(date.formatted(date: .numeric, time: .standard)) · \(context)",
                     "Модель: \(model)", "POST \(endpoint)", "Статус: \(status.rawValue)"]
        if let duration { parts.append(String(format: "Время: %.2f с", duration)) }
        parts += ["SYSTEM / INSTRUCTIONS\n\(system)", "USER\n\(user)"]
        if let selfNotes, !selfNotes.isEmpty { parts.append("ЗАМЕТКИ ЭТОГО ИГРОКА (отдельное сообщение)\n\(selfNotes)") }
        if let gameAdvice, !gameAdvice.isEmpty { parts.append("ПЛАН ИЗ ПРОШЛЫХ ПАРТИЙ (отдельное сообщение)\n\(gameAdvice)") }
        if let response { parts.append("ОТВЕТ МОДЕЛИ\n\(response)") }
        if let error { parts.append("ОШИБКА\n\(error)") }
        return parts.joined(separator: "\n\n")
    }
}

/// Only sanitized, bounded text is retained or published to the UI.
@MainActor
public final class ModelLog: ObservableObject {
    @Published public private(set) var entries: [ModelLogEntry] = []
    public let capacity: Int
    public init(capacity: Int = 300) { self.capacity = max(1, capacity) }

    @discardableResult
    public func begin(_ call: ChatCall, context: String, endpoint: URL) -> UUID {
        let id = UUID()
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        url?.user = nil; url?.password = nil; url?.query = nil; url?.fragment = nil
        func clean(_ text: String) -> String { Self.sanitize(text, secrets: [call.apiKey]) }
        let entry = ModelLogEntry(id: id, date: Date(), context: clean(context), model: clean(call.model),
                                  endpoint: clean(url?.string ?? ""), system: clean(call.system), user: clean(call.user),
                                  selfNotes: call.selfNotes.map(clean), gameAdvice: call.gameAdvice.map(clean))
        entries.insert(entry, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        return id
    }

    public func succeed(_ id: UUID, response: String, secrets: [String] = []) {
        update(id) { entry in
            entry.response = Self.sanitize(response, secrets: secrets)
            entry.status = .received
        }
    }

    public func fail(_ id: UUID, error: Error) {
        update(id) { entry in
            if error is CancellationError {
                entry.status = .cancelled
                entry.error = "Запрос отменён."
            } else {
                entry.status = .failed
                if let chat = error as? ChatError { entry.error = chat.userMessage }
                else if let network = error as? URLError { entry.error = "Ошибка соединения (URLError \(network.code.rawValue))." }
                else { entry.error = "Не удалось выполнить запрос к модели." }
            }
        }
    }

    public func clear() { entries.removeAll() }

    public func rejectMove(_ id: UUID, reason: String, secrets: [String] = []) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].status == .received else { return }
        entries[index].status = .failed
        entries[index].error = Self.sanitize("Судья отклонил ход: " + reason, secrets: secrets)
    }

    private func update(_ id: UUID, mutation: (inout ModelLogEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].status == .pending else { return }
        var entry = entries[index]
        mutation(&entry)
        entry.duration = max(0, Date().timeIntervalSince(entry.date))
        entries[index] = entry
    }

    public static func sanitize(_ text: String, secrets: [String] = []) -> String {
        var result = text
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        let patterns = [
            #"(?i)\bBearer\s+[^\s\"',;}]+"#,
            #"\b(?:sk|xai)-[A-Za-z0-9_-]{8,}"#,
            #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
            #"(?i)(?:access_token|refresh_token|id_token|api_key|authorization)\s*[\"']?\s*[:=]\s*[\"']?[^\s\"',;}]+"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        let limit = 32_000
        return result.count > limit ? String(result.prefix(limit)) + "\n[… журнал сократил длинный текст …]" : result
    }
}
