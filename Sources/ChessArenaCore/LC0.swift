import Combine
import Foundation

public enum LC0Error: Equatable, Sendable {
    case missing, weights, execution, timeout, protocolError, invalidMove

    public var userMessage: String {
        switch self {
        case .missing: return "LC0 не найден. Укажите исполняемый файл lc0 в настройках."
        case .weights: return "Файл нейросети LC0 недоступен. Выберите файл весов или оставьте автопоиск."
        case .execution: return "LC0 не смог запустить поиск. Проверьте файл нейросети и вычислительный backend."
        case .timeout: return "LC0 не завершил ответ вовремя. Проверьте подключение и продолжите партию."
        case .protocolError: return "LC0 не завершил обмен UCI. Проверьте выбранный исполняемый файл."
        case .invalidMove: return "LC0 вернул ход, недопустимый в текущей позиции. Партия приостановлена."
        }
    }
}

public struct LC0Settings: Equatable, Sendable {
    public var binary: String
    public var weights: String
    /// Empty means the installed engine's default backend.
    public var backend: String
    public var moveSeconds: Int

    public init(binary: String = LC0Settings.discoverBinary(), weights: String = "", backend: String = "", moveSeconds: Int = 3) {
        self.binary = binary; self.weights = weights; self.backend = backend; self.moveSeconds = moveSeconds
    }

    public static func discoverBinary() -> String {
        ["/opt/homebrew/bin/lc0", "/usr/local/bin/lc0", NSHomeDirectory() + "/.local/bin/lc0"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/lc0"
    }

    public func validate() throws {
        guard binary.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: binary) else { throw ChatError.lc0(.missing) }
        guard weights.isEmpty || (weights.hasPrefix("/") && FileManager.default.isReadableFile(atPath: weights)) else { throw ChatError.lc0(.weights) }
        guard (1...60).contains(moveSeconds), ["", "metal", "blas", "eigen"].contains(backend) else { throw ChatError.lc0(.execution) }
    }
}

/// Structured board data, independent of the natural-language prompts and private player notes.
public struct LC0Position: Equatable, Sendable {
    public var initialFEN: String
    public var moves: [String]
    public var legalMoves: [String]

    public init(referee: Referee) {
        legalMoves = referee.legalUCI
        if let fen = referee.initialFEN {
            initialFEN = fen; moves = referee.accepted.map(\.move.uci)
        } else if let first = referee.accepted.first {
            // Legacy saves lack the original position; retain all recoverable history.
            initialFEN = first.fenAfter; moves = referee.accepted.dropFirst().map(\.move.uci)
        } else {
            initialFEN = referee.position.fen; moves = []
        }
    }

    var command: String {
        "position fen \(initialFEN)" + (moves.isEmpty ? "" : " moves " + moves.joined(separator: " ")) + "\n"
    }

    func validate() throws {
        guard !initialFEN.contains("\n"), !initialFEN.contains("\r"),
              var position = Position.position(fen: initialFEN) else { throw ChatError.lc0(.protocolError) }
        for move in moves {
            guard let parsed = position.parseUCI(move), parsed.uci == move, position.isLegal(parsed) else { throw ChatError.lc0(.protocolError) }
            position = position.applying(parsed)
        }
        guard !legalMoves.isEmpty, Set(legalMoves) == Set(position.legalMoves().map(\.uci)) else { throw ChatError.lc0(.protocolError) }
    }
}

/// A fresh local process per move isolates searches across seats and cancels with the owning task.
public final class LC0Transport: ChatTransport, @unchecked Sendable {
    public static let localURL = URL(string: "local-uci://lc0")!
    private let lock = NSLock()
    private var configuration: LC0Settings
    private let timeoutOverride: TimeInterval?

    public init(settings: LC0Settings = LC0Settings(), timeout: TimeInterval? = nil) {
        configuration = settings; timeoutOverride = timeout
    }

    public func configure(_ settings: LC0Settings) { lock.withLock { configuration = settings } }
    public func requestURL(for call: ChatCall) -> URL { Self.localURL }

    public func complete(_ call: ChatCall) async throws -> String {
        guard call.route == .lc0, let position = call.chessPosition else { throw ChatError.lc0(.protocolError) }
        let settings = lock.withLock { configuration }
        try settings.validate(); try position.validate(); try Task.checkCancellation()
        let conversation = LC0Conversation(position: position, milliseconds: settings.moveSeconds * 1000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chessarena-lc0-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Disable ambient config files; weights default to lc0's installed network discovery.
        var arguments = ["--config=", "--logfile=", "--threads=2"]
        if !settings.weights.isEmpty { arguments.append("--weights=" + settings.weights) }
        if !settings.backend.isEmpty { arguments.append("--backend=" + settings.backend) }
        let environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        return try await NetworkTrace.track(.lc0Move, request: nil) { trace in
            do {
                let output = try await LocalCLIProcess().run(binary: settings.binary, arguments: arguments, directory: directory,
                    environment: environment, timeout: timeoutOverride ?? TimeInterval(settings.moveSeconds + 90),
                    initialInput: "uci\n", onLine: conversation.consume)
                await trace.payload(bytes: output.stdout.count + output.stderr.count, exitCode: output.status)
                try Task.checkCancellation()
                guard output.status == 0 else { throw ChatError.lc0(.execution) }
                guard let move = conversation.bestMove else { throw ChatError.lc0(.protocolError) }
                let data = try JSONSerialization.data(withJSONObject: ["move": move, "taunt": ""])
                return String(decoding: data, as: UTF8.self)
            } catch ChatError.cli(let error) {
                switch error {
                case .missing: throw ChatError.lc0(.missing)
                case .timeout: throw ChatError.lc0(.timeout)
                default: throw ChatError.lc0(.execution)
                }
            }
        }
    }
}

/// Used only on the process worker; no unchecked output is shown or treated as an instruction.
private final class LC0Conversation {
    private var phase = 0
    private let position: LC0Position
    private let milliseconds: Int
    private(set) var bestMove: String?
    init(position: LC0Position, milliseconds: Int) { self.position = position; self.milliseconds = milliseconds }

    func consume(_ line: String) throws -> String? {
        if phase == 0, line == "uciok" {
            phase = 1
            return "ucinewgame\nisready\n"
        }
        if phase == 1, line == "readyok" {
            phase = 2
            return position.command + "go movetime \(milliseconds)\n"
        }
        if phase == 2, line.hasPrefix("bestmove ") {
            let fields = line.split(separator: " ")
            guard fields.count >= 2, position.legalMoves.contains(String(fields[1])) else { throw ChatError.lc0(.invalidMove) }
            bestMove = String(fields[1]); phase = 3
            return "quit\n"
        }
        return nil
    }
}

@MainActor
public final class LC0Connection: ObservableObject {
    public let transport: LC0Transport
    @Published public var settings: LC0Settings { didSet {
        cancel(); transport.configure(settings)
        defaults.set(settings.binary, forKey: "lc0.binary")
        defaults.set(settings.weights, forKey: "lc0.weights")
        defaults.set(settings.backend, forKey: "lc0.backend")
        defaults.set(settings.moveSeconds, forKey: "lc0.seconds")
        status = "Настройки изменены. Можно проверить LC0 тестовым ходом."
    } }
    @Published public private(set) var busy = false
    @Published public private(set) var status = "Локальный движок. Проверка выполняет один тестовый ход."
    private var task: Task<Void, Never>?
    private let defaults: UserDefaults
    private var generation = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = LC0Settings(binary: defaults.string(forKey: "lc0.binary") ?? LC0Settings.discoverBinary(),
            weights: defaults.string(forKey: "lc0.weights") ?? "", backend: defaults.string(forKey: "lc0.backend") ?? "",
            moveSeconds: defaults.object(forKey: "lc0.seconds") as? Int ?? 3)
        self.settings = settings; self.transport = LC0Transport(settings: settings)
    }

    public func verify() {
        cancel(); busy = true; status = "LC0 загружает нейросеть и выбирает ход…"
        let attempt = generation
        task = Task { [weak self, transport] in
            var call = ChatCall(url: LC0Transport.localURL, apiKey: "", model: "Leela Chess Zero", system: "", user: "", route: .lc0)
            call.chessPosition = LC0Position(referee: Referee())
            do {
                let text = try await transport.complete(call)
                guard let self, !Task.isCancelled, self.generation == attempt else { return }
                self.status = "LC0 подключён · тестовый ход: \(ChatParser.moveIntent(from: text)?.move ?? "")"
            } catch {
                guard let self, self.generation == attempt else { return }
                self.status = error is CancellationError ? "Проверка отменена." : (error as? ChatError)?.userMessage ?? LC0Error.execution.userMessage
            }
            guard let self, self.generation == attempt else { return }
            self.busy = false; self.task = nil
        }
    }

    public func cancel() { task?.cancel(); task = nil; generation += 1; busy = false }
}
