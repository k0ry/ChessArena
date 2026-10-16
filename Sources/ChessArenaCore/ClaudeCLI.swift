import Foundation

public enum ClaudeCLIError: String, Equatable {
    case missing, incompatible, outdated, authentication, apiKeyMode, quota, model
    case execution, timeout, outputLimit, invalidResponse, tools

    public var userMessage: String {
        switch self {
        case .missing: return "Локальный Claude Code CLI не найден. Установите claude или выберите файл."
        case .incompatible: return "Нужен совместимый Claude Code CLI (2.1.0 или новее). Проверьте выбранный файл."
        case .outdated: return "Установленный Claude Code CLI не поддерживает эту модель. Обновите CLI командой claude update и повторите проверку."
        case .authentication: return "Войдите в Claude по подписке в локальном claude (/login) и повторите проверку."
        case .apiKeyMode: return "Локальный claude настроен на API-ключ, а не на подписку. Выполните /login по подписке в CLI."
        case .quota: return "Лимит использования подписки Claude исчерпан. Дождитесь его восстановления."
        case .model: return "Эта модель Claude недоступна в CLI. Выберите opus, sonnet, haiku или полный ID модели."
        case .timeout: return "Локальный CLI не ответил вовремя. Запрос остановлен; можно повторить ход."
        case .outputLimit: return "Ответ CLI превысил допустимый размер. Запрос остановлен."
        case .invalidResponse: return "CLI не вернул завершённый ответ модели. Повторите проверку подключения."
        case .tools: return "CLI запросил инструмент. Шахматный запрос остановлен."
        case .execution: return "Не удалось выполнить запрос через локальный Claude Code CLI."
        }
    }

    static func classify(_ text: String) -> Self {
        let text = text.lowercased()
        if ["credit balance", "billing"].contains(where: text.contains) { return .apiKeyMode }
        if ["oauth", "401", "authentication", "unauthorized", "not logged in", "please log in", "/login", "token is invalid", "token expired"].contains(where: text.contains) { return .authentication }
        if ["rate limit", "usage limit", "429", "quota", "limit reached", "exceeded your", "resource_exhausted"].contains(where: text.contains) { return .quota }
        if ["does not support this model", "or newer is required", "newer version of claude code"].contains(where: text.contains) { return .outdated }
        if text.contains("model"), ["not found", "invalid", "not support", "unknown", "does not exist"].contains(where: text.contains) { return .model }
        if ["timed out", "timeout"].contains(where: text.contains) { return .timeout }
        if ["permission", "tool denied", "tool call", "tool use"].contains(where: text.contains) { return .tools }
        return .execution
    }
}

/// Non-identifying account facts from the CLI's own configuration.
public struct ClaudeAccountInfo: Equatable, Sendable {
    public var billingType: String
    public var organizationType: String
    public var extraUsageEnabled: Bool
}

/// Official Claude Code CLI in print mode, isolated from tools, MCP, user settings and saved sessions.
public struct ClaudeCLI: Sendable {
    public static let minimumSupportedVersion = (major: 2, minor: 1, patch: 0)
    public static let localURL = URL(string: "local-cli://claude")!
    /// Aliases the CLI resolves to the latest model of each tier, plus full IDs of current models (October 2026).
    /// Fable has no alias: the CLI needs the full ID and version 2.1.251 or newer. Other IDs are typed manually.
    public static let aliases: [ClaudeModel] = [
        ClaudeModel(id: "claude-fable-5-1", name: "claude-fable-5-1 · Fable 5.1"),
        ClaudeModel(id: "claude-opus-5-5", name: "claude-opus-5-5 · Opus 5.5"),
        ClaudeModel(id: "claude-sonnet-5-5", name: "claude-sonnet-5-5 · Sonnet 5.5"),
        ClaudeModel(id: "claude-haiku-5-5", name: "claude-haiku-5-5 · Haiku 5.5"),
        ClaudeModel(id: "opus", name: "opus · актуальная Opus"),
        ClaudeModel(id: "sonnet", name: "sonnet · актуальная Sonnet"),
        ClaudeModel(id: "haiku", name: "haiku · актуальная Haiku"),
    ]
    public let binary: String
    let home: URL

    public init(binary: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.binary = binary; self.home = home
    }

    public static func discover() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) ?? home + "/.local/bin/claude"
    }

    public static func cancelAll() { LocalCLIProcess.cancelAll() }

    /// "2.1.29 (Claude Code)" → supported when the major matches and the version is not older than the minimum.
    public static func isSupportedVersion(_ raw: String) -> Bool {
        guard let core = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first?.split(separator: "-").first else { return false }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return false }
        let min = minimumSupportedVersion
        guard major == min.major else { return false }
        return (minor, patch) >= (min.minor, min.patch)
    }

    public static func validModel(_ model: String) -> Bool {
        model.range(of: #"^(opus|sonnet|haiku|claude-[A-Za-z0-9._-]+)$"#, options: .regularExpression) != nil
    }

    static func environment(from source: [String: String], userName: String = NSUserName()) -> [String: String] {
        // Keep the user's home for the CLI's own login storage. Never import API keys or OAuth tokens.
        // The CLI finds its Keychain login by the account name in USER; without it every request reads as "not logged in".
        let allowed = Set(["HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME", "SSL_CERT_FILE", "SSL_CERT_DIR",
                           "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "all_proxy", "no_proxy"])
        var env = source.filter { allowed.contains($0.key) }
        if env["USER"]?.isEmpty != false, !userName.isEmpty { env["USER"] = userName }
        if env["LOGNAME"]?.isEmpty != false, let user = env["USER"] { env["LOGNAME"] = user }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["DISABLE_AUTOUPDATER"] = "1"
        env["DISABLE_TELEMETRY"] = "1"
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return env
    }

    /// Reference messages follow the task as separate paragraphs; the system prompt travels in its own flag.
    static func prompt(for call: ChatCall) -> String {
        call.inputMessages.compactMap { $0["content"] }.joined(separator: "\n\n")
    }

    static func arguments(for call: ChatCall) -> [String] {
        ["-p", prompt(for: call), "--output-format", "json", "--model", call.model.trimmingCharacters(in: .whitespacesAndNewlines),
         "--system-prompt", call.system, "--tools", "", "--strict-mcp-config", "--setting-sources", "",
         "--no-session-persistence", "--disable-slash-commands", "--permission-mode", "dontAsk"]
    }

    public func checkVersion() async throws {
        try await NetworkTrace.track(.claudeVersion) { trace in
            guard binary.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: binary) else { throw ChatError.claudeCLI(.missing) }
            let result = try await run(["--version"], timeout: 15)
            await trace.payload(bytes: result.stdout.count + result.stderr.count, exitCode: result.status)
            guard result.status == 0, Self.isSupportedVersion(String(decoding: result.stdout, as: UTF8.self)) else {
                throw ChatError.claudeCLI(.incompatible)
            }
        }
    }

    /// Fail closed on the CLI's own configuration without rewriting it.
    public func validateAccount() throws -> ClaudeAccountInfo {
        let url = home.appendingPathComponent(".claude.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw ChatError.claudeCLI(.authentication) }
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw ChatError.claudeCLI(.authentication) }
            object = value
        } catch let error as ChatError { throw error }
        catch { throw ChatError.claudeCLI(.authentication) }
        if let key = object["primaryApiKey"] as? String, !key.isEmpty { throw ChatError.claudeCLI(.apiKeyMode) }
        guard let account = object["oauthAccount"] as? [String: Any], !account.isEmpty else { throw ChatError.claudeCLI(.authentication) }
        return ClaudeAccountInfo(billingType: account["billingType"] as? String ?? "",
                                 organizationType: account["organizationType"] as? String ?? "",
                                 extraUsageEnabled: account["hasExtraUsageEnabled"] as? Bool ?? false)
    }

    /// Version, account and one short request: the only proof that the subscription answers.
    public func verify(model: String) async throws -> ClaudeAccountInfo {
        try await checkVersion()
        let info = try validateAccount()
        let call = ChatCall(url: Self.localURL, apiKey: "", model: model,
                            system: "Reply with the single word OK and nothing else.", user: "Sound check.", route: .claudeCLI, effort: "low")
        let reply = try await complete(call, operation: .claudeVerify)
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.claudeCLI(.invalidResponse) }
        return info
    }

    public func complete(_ call: ChatCall) async throws -> String {
        try await complete(call, operation: .claudeCompletion)
    }

    func complete(_ call: ChatCall, operation: NetworkOperation) async throws -> String {
        try await NetworkTrace.track(operation) { trace in
            guard Self.validModel(call.model.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ChatError.claudeCLI(.model) }
            _ = try validateAccount()
            try await checkVersion()
            let arguments = Self.arguments(for: call)
            guard arguments.joined().utf8.count <= 256 * 1024 else { throw ChatError.claudeCLI(.outputLimit) }
            let output = try await run(arguments, timeout: call.effort == "low" ? 100 : 600)
            await trace.payload(bytes: output.stdout.count + output.stderr.count, exitCode: output.status)
            return try Self.parse(output)
        }
    }

    static func parse(_ output: CLIOutput) throws -> String {
        let diagnostics = String(decoding: output.stderr, as: UTF8.self)
        guard let object = jsonObject(in: output.stdout) else {
            if !diagnostics.isEmpty { throw ChatError.claudeCLI(.classify(diagnostics)) }
            throw ChatError.claudeCLI(output.status == 0 ? .invalidResponse : .execution)
        }
        let result = object["result"] as? String ?? ""
        if let denials = object["permission_denials"] as? [Any], !denials.isEmpty { throw ChatError.claudeCLI(.tools) }
        if object["is_error"] as? Bool == true || (object["subtype"] as? String).map({ $0 != "success" }) == true || output.status != 0 {
            throw ChatError.claudeCLI(.classify(result + "\n" + diagnostics))
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.claudeCLI(.invalidResponse) }
        return result
    }

    private static func jsonObject(in data: Data) -> [String: Any]? {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return object }
        // Tolerate a stray diagnostic line before the single JSON result.
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    private func run(_ arguments: [String], timeout: TimeInterval) async throws -> CLIOutput {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("chessarena-claude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        do {
            return try await LocalCLIProcess().run(binary: binary, arguments: arguments, directory: workspace,
                                                  environment: Self.environment(from: ProcessInfo.processInfo.environment), timeout: timeout)
        } catch ChatError.cli(let reason) {
            // LocalCLIProcess reports in Gemini terms; translate to the Claude CLI vocabulary.
            switch reason {
            case .missing: throw ChatError.claudeCLI(.missing)
            case .timeout: throw ChatError.claudeCLI(.timeout)
            case .outputLimit: throw ChatError.claudeCLI(.outputLimit)
            default: throw ChatError.claudeCLI(.execution)
            }
        }
    }
}
