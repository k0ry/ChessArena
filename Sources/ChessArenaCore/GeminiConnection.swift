import AppKit
import Foundation

@MainActor
public final class GeminiConnection: ObservableObject {
    @Published public var path: String {
        didSet {
            guard path != oldValue else { return }
            task?.cancel(); generation += 1; busy = false
            models = []; verifiedModels = []; status = "Проверьте локальный CLI"
            UserDefaults.standard.set(path, forKey: "geminiCLIPath")
        }
    }
    @Published public private(set) var models: [GeminiModel] = []
    @Published public private(set) var verifiedModels: Set<String> = []
    @Published public private(set) var busy = false
    @Published public private(set) var status = "Подключение через локальный Antigravity CLI"
    private var task: Task<Void, Never>?
    private var generation = 0

    public init() { path = UserDefaults.standard.string(forKey: "geminiCLIPath") ?? GeminiCLI.discover() }
    public var cli: GeminiCLI { GeminiCLI(binary: path) }

    public func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Выберите локальный исполняемый файл Antigravity CLI (agy)"
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    public func refresh() {
        perform { cli in
            let models = try await cli.models()
            return (models, nil)
        }
    }

    public func verify(model: String) {
        perform { cli in
            let models = try await cli.models()
            guard models.contains(where: { $0.id == model }) else { throw ChatError.cli(.model) }
            let position = Position.standard()
            let legal = position.legalMoves().map(\.uci)
            let prompt = Prompts.player(side: .white, fen: position.fen, legal: legal, history: [], rejection: nil)
            let content = try await cli.complete(ChatCall(url: URL(string: "local-cli://antigravity")!, apiKey: "", model: model,
                                                         system: prompt.system, user: prompt.user, route: .geminiCLI))
            guard let intent = ChatParser.moveIntent(from: content), legal.contains(intent.move) else { throw ChatError.cli(.invalidResponse) }
            return (models, model)
        }
    }

    private func perform(_ action: @escaping (GeminiCLI) async throws -> ([GeminiModel], String?)) {
        task?.cancel(); generation += 1
        let attempt = generation, client = cli
        busy = true; status = "Проверяю локальный CLI…"
        task = Task {
            defer { if generation == attempt { busy = false; task = nil } }
            do {
                let (catalog, verified) = try await action(client)
                guard !Task.isCancelled, generation == attempt else { return }
                models = catalog
                if let verified {
                    verifiedModels.insert(verified)
                    status = "Локальный Gemini ответил. Дополнительные AI credits отключены."
                } else {
                    status = "CLI 1.3.3 найден, каталог загружен. Проверьте выбранную модель тестовым ходом."
                }
            } catch is CancellationError { }
            catch {
                guard generation == attempt else { return }
                verifiedModels = []
                status = (error as? ChatError)?.userMessage ?? GeminiCLIError.execution.userMessage
            }
        }
    }

    public func cancel() {
        task?.cancel(); task = nil; generation += 1; busy = false
        status = "Проверка отменена"
    }

    public func login() {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            status = GeminiCLIError.missing.userMessage; return
        }
        do {
            // A user-visible local terminal owns the interactive login and all credentials.
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ChessArena/GeminiLogin")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = directory.appendingPathComponent("Login-Gemini.command")
            func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let content = "#!/bin/sh\ncd " + quote(directory.path) + " || exit 1\nexec " + quote(path) + "\n"
            try content.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            guard NSWorkspace.shared.open(script) else { throw ChatError.cli(.execution) }
            status = "Завершите вход Google в локальном терминале, затем нажмите «Обновить модели»."
            verifiedModels = []
        } catch { status = GeminiCLIError.execution.userMessage }
    }
}
