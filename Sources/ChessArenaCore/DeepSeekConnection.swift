import Combine
import Foundation

@MainActor
public final class DeepSeekConnection: ObservableObject {
    @Published public private(set) var models: [DeepSeekModel] = []
    @Published public private(set) var status = "Введите API-ключ DeepSeek и обновите каталог моделей."
    @Published public private(set) var busy = false
    private let load: (String) async throws -> [DeepSeekModel]
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(baseURL: URL = ModelCatalog.deepSeekAPI, session: URLSession = .shared) {
        load = { try await DeepSeekAPI.catalog(baseURL: baseURL, apiKey: $0, session: session) }
    }

    init(load: @escaping (String) async throws -> [DeepSeekModel]) { self.load = load }

    public func refresh(key: String) {
        cancel()
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { status = "Введите API-ключ DeepSeek."; return }
        busy = true
        status = "Загружаю каталог моделей DeepSeek…"
        let attempt = generation
        task = Task { [weak self, load] in
            do {
                let models = try await load(key)
                guard let self, !Task.isCancelled, self.generation == attempt else { return }
                self.models = models
                self.status = models.isEmpty
                    ? "Каталог пуст. Введите ID модели вручную."
                    : "Каталог загружен: \(models.count) моделей. Доступ подтверждается первым запросом хода."
            } catch {
                guard let self, self.generation == attempt else { return }
                self.status = error is CancellationError ? "Загрузка отменена." : (error as? ChatError)?.userMessage ?? ChatError.transport.userMessage
            }
            guard let self, self.generation == attempt else { return }
            self.busy = false; self.task = nil
        }
    }

    public func keyChanged() {
        cancel()
        models = []
        status = "Ключ изменён. Обновите каталог моделей."
    }

    public func cancel() {
        task?.cancel(); task = nil; generation += 1; busy = false
    }
}
