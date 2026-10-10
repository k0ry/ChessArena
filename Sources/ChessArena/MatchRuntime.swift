import AppKit
import ChessArenaCore
import Foundation

@MainActor
final class MatchRuntime: ObservableObject {
    @Published var picture = BroadcastPicture.empty
    let chatGPT = ChatGPTConnection()
    let modelLog = ModelLog()
    private var logWindow: NSWindow?

    func showLog() {
        if let logWindow { logWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ChessArena Log"
        window.isReleasedWhenClosed = false
        window.contentView = ModelLogView.host(log: modelLog)
        window.contentMinSize = NSSize(width: 860, height: 520)
        window.center()
        window.makeKeyAndOrderFront(nil)
        logWindow = window
    }
    @Published var useChatGPTLogin = true
    @Published var grokKey = ""
    @Published var chatKey = ""
    @Published var whitePlayer = PlayerConfiguration(provider: .grok) {
        didSet { updatePlayerNames() }
    }
    @Published var blackPlayer = PlayerConfiguration(provider: .chatGPT) {
        didSet { updatePlayerNames() }
    }
    @Published var hostModel = ModelCatalog.grokModel
    @Published var status = "Готово к эфиру"
    @Published var moveNumber = 1
    @Published var paused = false
    @Published var matchRunning = false

    @Published private(set) var series = MatchSeries()
    @Published private(set) var nextGameIn: Int?
    @Published var language = BroadcastLanguage(rawValue: UserDefaults.standard.string(forKey: "broadcastLanguage") ?? "") ?? .russian {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "broadcastLanguage")
            engine?.language = language
            voice.language = language
        }
    }
    var score: SeriesScore { series.score }
    var result: GameEnd? { series.result }
    var resultTitle: String {
        result.map { language.result($0, white: picture.whiteName, black: picture.blackName) } ?? ""
    }
    private var scoreKey: String {
        "seriesScore." + [whitePlayer.provider.rawValue, blackPlayer.provider.rawValue].joined(separator: "|")
    }

    let scene = BoardScene()
    private let secrets = KeychainSecretStore(service: "com.chessarena.broadcast")
    private let voice = SystemVoice()
    private var engine: MatchEngine?
    private var startedAt: Date?
    private var ticker: Task<Void, Never>?

    func loadKeys() {
        grokKey = (try? secrets.load(account: "grok")) ?? ""
        // API fallback is entered explicitly; ChatGPT uses its own OAuth session.
        Task { await chatGPT.restore() }
        loadScore()
    }

    func tone() {
        guard engine == nil else { return }
        Task {
            voice.language = language
            _ = await voice.speak(language.toneTest, kind: .tone)
        }
    }

    func startMatch() {
        guard !matchRunning, engine == nil else { return }
        guard validatePlayers() else { return }
        try? secrets.save(account: "grok", secret: grokKey)
        if !useChatGPTLogin { try? secrets.save(account: "chatgpt", secret: chatKey) }
        let round = series.start()
        matchRunning = true
        launchRound(round)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 33_000_000) } catch { return }
                guard let self else { return }
                await self.tick()
            }
        }
    }

    func stopMatch() {
        series.stop()
        ticker?.cancel(); ticker = nil
        engine?.stop()
        if let engine { picture = engine.picture }
        voice.stop()
        if let engine { finishArchive(engine) }
        engine = nil
        nextGameIn = nil
        paused = false
        matchRunning = false
        status = language.text("Серия остановлена", "Series stopped")
    }

    func resetScore() {
        guard !matchRunning else { return }
        series = MatchSeries()
        UserDefaults.standard.removeObject(forKey: scoreKey)
    }

    private func loadScore() {
        guard !matchRunning else { return }
        let saved = UserDefaults.standard.data(forKey: scoreKey)
            .flatMap { try? JSONDecoder().decode(SeriesScore.self, from: $0) } ?? SeriesScore()
        series = MatchSeries(score: saved)
    }

    private func launchRound(_ round: UUID) {
        scene.show(position: .standard())
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChessArena", isDirectory: true)
            .appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + round.uuidString, isDirectory: true)
        let white = whitePlayer.seat(side: .white, grokKey: grokKey, chatKey: chatKey)
        let black = blackPlayer.seat(side: .black, grokKey: grokKey, chatKey: chatKey)
        let archive = MatchArchive(directory: folder, whiteName: white.name, blackName: black.name)
        let host = Seat(name: "Host", baseURL: ModelCatalog.grokAPI,
                        model: hostModel.trimmingCharacters(in: .whitespacesAndNewlines),
                        apiKey: grokKey.trimmingCharacters(in: .whitespacesAndNewlines), side: .white)
        let match = MatchEngine(
            scene: scene,
            voice: voice,
            transport: ArenaChatTransport(connection: useChatGPTLogin ? chatGPT : nil),
            archive: archive,
            white: white,
            black: black,
            host: host
        )
        match.animationDuration = 1.2
        match.modelLog = modelLog
        match.language = language
        voice.language = language
        match.onGameEnded = { [weak self] end in
            guard let self, self.series.complete(round: round, result: end, now: Date().timeIntervalSinceReferenceDate) else { return }
            self.nextGameIn = 30
            if let data = try? JSONEncoder().encode(self.series.score) {
                UserDefaults.standard.set(data, forKey: self.scoreKey)
            }
        }
        engine = match
        matchRunning = true
        startedAt = Date()
        nextGameIn = nil
        paused = false
        moveNumber = 1
        picture = match.picture
        status = language.text("Партия идёт", "Match in progress")
        Task {
            guard self.engine === match else { return }
            do {
                try await match.start(at: 0)
                guard self.engine === match else { return }
                self.picture = match.picture
            } catch {
                guard self.engine === match else { return }
                self.stopMatch()
                self.status = "Архив не открылся. Проверьте доступ к папке Документы."
                self.engine = nil
                self.matchRunning = false
                self.ticker?.cancel()
            }
        }
    }

    func resume() {
        guard let engine, engine.paused else { return }
        guard validatePlayers() else { return }
        engine.white = whitePlayer.seat(side: .white, grokKey: grokKey, chatKey: chatKey)
        engine.black = blackPlayer.seat(side: .black, grokKey: grokKey, chatKey: chatKey)
        engine.host.apiKey = grokKey.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.host.model = hostModel.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.resume()
        paused = false
        status = "Партия идёт"
    }

    var needsChatGPT: Bool {
        whitePlayer.provider == .chatGPT || blackPlayer.provider == .chatGPT
    }

    func selectAvailableChatGPTModels() {
        guard useChatGPTLogin, let first = chatGPT.models.first else { return }
        if whitePlayer.provider == .chatGPT, !chatGPT.models.contains(where: { $0.id == whitePlayer.model }) {
            whitePlayer.model = first.id
        }
        if blackPlayer.provider == .chatGPT, !chatGPT.models.contains(where: { $0.id == blackPlayer.model }) {
            blackPlayer.model = first.id
        }
    }

    private func updatePlayerNames() {
        guard !matchRunning else { return }
        picture.whiteName = whitePlayer.provider.rawValue
        picture.blackName = blackPlayer.provider.rawValue
        loadScore()
    }

    private func validatePlayers() -> Bool {
        guard !grokKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Введите ключ xAI для ведущего и игроков Grok"; return false
        }
        guard !hostModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Укажите модель ведущего"; return false
        }
        if needsChatGPT {
            if useChatGPTLogin {
                guard chatGPT.connected else {
                    status = "Сначала нажмите Continue with ChatGPT"; return false
                }
            } else if chatKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                status = "Введите ключ OpenAI или войдите через ChatGPT"; return false
            }
        }
        for (name, player) in [("белых", whitePlayer), ("чёрных", blackPlayer)] {
            guard !player.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                status = "Укажите модель для \(name)"; return false
            }
            if player.provider == .chatGPT, useChatGPTLogin,
               !chatGPT.models.contains(where: { $0.id == player.model }) {
                status = "Выберите доступную модель ChatGPT для \(name)"; return false
            }
        }
        return true
    }

    private func tick() async {
        guard let engine, let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        scene.applyCamera(at: elapsed)
        if engine.paused {
            engine.white = whitePlayer.seat(side: .white, grokKey: grokKey, chatKey: chatKey)
            engine.black = blackPlayer.seat(side: .black, grokKey: grokKey, chatKey: chatKey)
            engine.host.apiKey = grokKey.trimmingCharacters(in: .whitespacesAndNewlines)
            engine.host.model = hostModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        await engine.advance(to: elapsed)
        guard self.engine === engine, series.running else { return }
        if let frame = scene.copyFrame() {
            engine.appendFrame(frame)
        }
        picture = engine.picture
        moveNumber = engine.referee.position.fullmove
        paused = engine.paused
        let now = Date().timeIntervalSinceReferenceDate
        nextGameIn = series.remaining(at: now)
        if let seconds = nextGameIn {
            status = language.text("Следующая партия через \(seconds) с", "Next game in \(seconds) s")
        } else if engine.paused {
            status = engine.pauseReason ?? language.text("Автоматический повтор запроса…", "Retrying automatically…")
        } else {
            status = language.text("Партия идёт", "Match in progress")
        }
        if let round = series.nextRoundIfDue(at: now) {
            engine.stop()
            finishArchive(engine)
            self.engine = nil
            launchRound(round)
        }
    }

    private func finishArchive(_ match: MatchEngine) {
        Task {
            do { try await match.closeArchive() }
            catch { print("ChessArena: could not finish match archive.") }
        }
    }
}
