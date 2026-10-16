import AppKit
import Foundation

/// Control-window state for both Claude access modes: the local Claude Code CLI (subscription) and an API key.
@MainActor
public final class ClaudeConnection: ObservableObject {
    // API-key mode
    @Published public private(set) var models: [ClaudeModel] = []
    @Published public private(set) var status = "Введите API-ключ Anthropic и обновите каталог моделей."
    public var baseURL: URL

    // Subscription mode
    @Published public var path: String {
        didSet {
            guard path != oldValue else { return }
            task?.cancel(); generation += 1; busy = false
            cliVerified = false; account = nil
            cliStatus = "Проверьте локальный Claude Code CLI."
            UserDefaults.standard.set(path, forKey: "claudeCLIPath")
        }
    }
    @Published public private(set) var cliVerified = false
    @Published public private(set) var cliStatus = "Подключение по подписке через локальный Claude Code CLI."
    @Published public private(set) var account: ClaudeAccountInfo?

    @Published public private(set) var busy = false
    private let session: URLSession
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(baseURL: URL = ModelCatalog.anthropicAPI, session: URLSession = .shared) {
        self.baseURL = baseURL; self.session = session
        path = UserDefaults.standard.string(forKey: "claudeCLIPath") ?? ClaudeCLI.discover()
    }

    public var cli: ClaudeCLI { ClaudeCLI(binary: path) }

    // MARK: API key

    public func refresh(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { status = "Введите API-ключ Anthropic."; return }
        begin(status: nil, cliStatus: nil)
        status = "Загружаю каталог моделей Claude…"
        let attempt = generation
        task = Task {
            defer { if generation == attempt { busy = false; task = nil } }
            do {
                let catalog = try await AnthropicAPI.catalog(baseURL: baseURL, apiKey: trimmed, session: session)
                guard !Task.isCancelled, generation == attempt else { return }
                models = catalog
                status = catalog.isEmpty
                    ? "Ключ принят, но каталог пуст. Введите ID модели вручную."
                    : "Каталог загружен: \(catalog.count) моделей. Доступ к конкретной модели подтверждается первым запросом."
            } catch is CancellationError { }
            catch {
                guard generation == attempt else { return }
                status = (error as? ChatError)?.userMessage ?? ChatError.transport.userMessage
            }
        }
    }

    public func keyChanged() {
        task?.cancel(); task = nil; generation += 1; busy = false
        models = []
        status = "Ключ изменён. Обновите каталог моделей."
    }

    // MARK: Subscription (local CLI)

    public func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Выберите локальный исполняемый файл Claude Code CLI (claude)"
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    /// Verifies version, subscription login and one short reply. The only proof the subscription answers.
    public func verifyCLI(model: String) {
        begin(status: nil, cliStatus: "Проверяю локальный Claude Code CLI…")
        let attempt = generation, client = cli
        let chosen = ClaudeCLI.validModel(model.trimmingCharacters(in: .whitespacesAndNewlines)) ? model : "sonnet"
        task = Task {
            defer { if generation == attempt { busy = false; task = nil } }
            do {
                let info = try await client.verify(model: chosen)
                guard !Task.isCancelled, generation == attempt else { return }
                account = info
                cliVerified = true
                var text = "Локальный Claude ответил по подписке"
                if !info.organizationType.isEmpty { text += " (\(info.organizationType))" }
                text += "."
                if info.extraUsageEnabled {
                    text += " В аккаунте включён дополнительный расход сверх лимита плана; отключить его можно только в настройках claude.ai."
                }
                cliStatus = text
            } catch is CancellationError { }
            catch {
                guard generation == attempt else { return }
                cliVerified = false; account = nil
                cliStatus = (error as? ChatError)?.userMessage ?? ClaudeCLIError.execution.userMessage
            }
        }
    }

    public func login() {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            cliStatus = ClaudeCLIError.missing.userMessage; return
        }
        do {
            // A user-visible local terminal owns the interactive login and all credentials.
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ChessArena/ClaudeLogin")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = directory.appendingPathComponent("Login-Claude.command")
            func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let content = "#!/bin/sh\ncd " + quote(directory.path) + " || exit 1\n"
                + "echo 'ChessArena: войдите в Claude по подписке. Если окно входа не открылось, введите /login.'\n"
                + "exec " + quote(path) + " /login\n"
            try content.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            guard NSWorkspace.shared.open(script) else { throw ChatError.claudeCLI(.execution) }
            cliStatus = "Завершите вход Claude в локальном терминале, затем нажмите «Проверить подключение»."
            cliVerified = false; account = nil
        } catch { cliStatus = ClaudeCLIError.execution.userMessage }
    }

    public func cancel() {
        task?.cancel(); task = nil; generation += 1; busy = false
        cliStatus = "Проверка отменена."
    }

    private func begin(status: String?, cliStatus: String?) {
        task?.cancel(); generation += 1
        busy = true
        if let status { self.status = status }
        if let cliStatus { self.cliStatus = cliStatus }
    }
}
