import AppKit
import ChessArenaCore
import Foundation

@MainActor
final class MatchRuntime: ObservableObject {
    @Published var picture = BroadcastPicture.empty
    let chatGPT = ChatGPTConnection()
    let gemini = GeminiConnection()
    let claude = ClaudeConnection()
    let deepseek = DeepSeekConnection()
    let lc0 = LC0Connection()
    let modelLog = ModelLog()
    private var logWindow: NSWindow?
    private var networkLogWindow: NSWindow?

    func showNetworkLog() {
        if let networkLogWindow { networkLogWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ChessArena · Log сети"
        window.isReleasedWhenClosed = false
        window.contentView = NetworkLogView.host(log: .shared)
        window.contentMinSize = NSSize(width: 1000, height: 520)
        window.center()
        window.makeKeyAndOrderFront(nil)
        networkLogWindow = window
    }


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
    @Published var useChatGPTLogin = true { didSet { saveState() } }
    @Published var claudeAccess: ClaudeAccess = .subscription { didSet { saveState() } }
    /// Stage-only presentation flags: hidden on every launch and never written to the session.
    @Published var showThinkingNotes = false
    @Published var showTaunts = false
    /// Which comedic persona each model plays; seeded with the initial table when the session has none.
    private var personas = PersonaAssignments.initial
    @Published var voiceProvider: VoiceProviderChoice = .system { didSet { voice.stop(); voice.provider = voiceProvider; saveState() } }
    @Published var speechKey = "" { didSet { voice.stop(); voice.apiKey = speechKey; saveKey(speechKey, account: "openai-speech") } }
    @Published var openAIVoice = "onyx" { didSet { voice.hostVoice = openAIVoice; saveState() } }
    @Published var qwenVoice = "Ryan" { didSet { voice.stop(); voice.qwenVoice = qwenVoice; saveState() } }
    @Published var qwenCasting = QwenVoiceCasting() { didSet { voice.stop(); voice.qwenCasting = qwenCasting; saveState() } }
    @Published private(set) var previewProfile: VoiceProfile?
    private var voicePreview: Task<Void, Never>?
    private var previewID = UUID()
    @Published var grokKey = "" { didSet { saveKey(grokKey, account: "grok") } }
    @Published var chatKey = "" { didSet { saveKey(chatKey, account: "chatgpt") } }
    @Published var deepSeekKey = "" {
        didSet {
            saveKey(deepSeekKey, account: "deepseek")
            if deepSeekKey != oldValue { deepseek.keyChanged() }
        }
    }
    @Published var claudeKey = "" {
        didSet {
            saveKey(claudeKey, account: "anthropic")
            if claudeKey != oldValue { claude.keyChanged() }
        }
    }
    @Published var whitePlayer = PlayerConfiguration(provider: .grok) {
        didSet { updatePlayerNames() }
    }
    @Published var blackPlayer = PlayerConfiguration(provider: .chatGPT) {
        didSet { updatePlayerNames() }
    }
    @Published var hostPlayer = PlayerConfiguration(provider: .grok) { didSet { saveState() } }
    @Published private(set) var persistenceError: String?
    @Published var status = "Готово к эфиру"
    @Published var moveNumber = 1
    @Published var paused = false
    @Published var matchRunning = false
    @Published private(set) var canRepeatRequest = false

    @Published private(set) var series = MatchSeries()
    @Published private(set) var nextGameIn: Int?
    @Published private(set) var showResultSplash = false
    @Published var language = BroadcastLanguage(rawValue: UserDefaults.standard.string(forKey: "broadcastLanguage") ?? "") ?? .russian {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "broadcastLanguage")
            engine?.language = language
            voice.language = language
            saveState()
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
    let voice = BroadcastVoice()
    private var engine: MatchEngine?
    private var startedAt: Date?
    private var ticker: Task<Void, Never>?

    private let sessionStore = SessionStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ChessArena/session.json"))
    private var loaded = false
    private var restoring = false
    private var savingEnabled = true
    private var saveFailed = false
    private var savedGame: GameCheckpoint?
    private var gameMemory = GameMemory()

    func loadKeys() {
        guard !loaded else { return }
        loaded = true
        restoring = true
        grokKey = (try? secrets.load(account: "grok")) ?? ""
        chatKey = (try? secrets.load(account: "chatgpt")) ?? ""
        claudeKey = (try? secrets.load(account: "anthropic")) ?? ""
        deepSeekKey = (try? secrets.load(account: "deepseek")) ?? ""
        speechKey = (try? secrets.load(account: "openai-speech")) ?? ""
        loadScore()
        do {
            if let saved = try sessionStore.load() {
                voiceProvider = saved.voiceProvider ?? .system
                openAIVoice = saved.openAIVoice ?? "onyx"
                qwenVoice = saved.qwenVoice.flatMap { LocalQwenConfiguration.voices.contains($0) ? $0 : nil } ?? "Ryan"
                qwenCasting = QwenVoiceCasting(entries: saved.qwenPersonaVoices ?? [:])
                whitePlayer = saved.white
                blackPlayer = saved.black
                hostPlayer = saved.hostConfiguration
                useChatGPTLogin = saved.useChatGPTLogin
                claudeAccess = saved.claudeAccess ?? .subscription
                if let saved = saved.personas, !saved.isEmpty { personas = saved }
                language = saved.language
                series = saved.series
                showResultSplash = saved.series.result != nil
                savedGame = saved.game
                gameMemory = saved.gameMemory ?? saved.game?.gameMemory ?? GameMemory()
                scene.restoreCamera(saved.camera)
                if let game = saved.game {
                    scene.show(position: game.referee.position)
                    picture = game.picture
                    picture.thinkingSide = nil
                    picture.thinkingSelfNotes = nil
                    picture.pausedPlayer = nil
                    moveNumber = game.referee.position.fullmove
                }
                // Restoring the board must not send a move or advance a finished series.
                series.stop()
                matchRunning = false
                nextGameIn = nil
                status = canContinueMatch
                    ? "Партия сохранена. Нажмите «Продолжить партию»."
                    : "Сохранённое состояние восстановлено"
            }
        } catch {
            // Keep an unreadable/future-format file for recovery instead of silently overwriting it.
            let backup = sessionStore.url.deletingLastPathComponent()
                .appendingPathComponent("session-unreadable-" + UUID().uuidString + ".json")
            do {
                try FileManager.default.copyItem(at: sessionStore.url, to: backup)
                persistenceError = "Сохранение не удалось прочитать. Исходный файл сохранён как \(backup.lastPathComponent)."
            } catch {
                savingEnabled = false
                persistenceError = "Не удалось прочитать сохранение. Автосохранение отключено, чтобы не затереть файл."
            }
        }
        restoring = false
        scene.onCameraChanged = { [weak self] in self?.saveState() }
        Task { await chatGPT.restore() }
    }

    private func saveKey(_ value: String, account: String) {
        guard loaded, !restoring else { return }
        do { try secrets.save(account: account, secret: value) }
        catch { persistenceError = "Не удалось сохранить ключ в Keychain." }
    }

    /// Called synchronously after game mutations, once a second for the clock, and on quit.
    func saveState() {
        guard loaded, !restoring, savingEnabled else { return }
        if let engine { savedGame = engine.checkpoint; gameMemory = engine.gameMemory }
        if let end = savedGame?.referee.end, let round = series.roundID,
           series.complete(round: round, result: end, now: Date().timeIntervalSinceReferenceDate, startIntermission: false) {
            nextGameIn = nil
            canRepeatRequest = false
            if let data = try? JSONEncoder().encode(series.score) {
                UserDefaults.standard.set(data, forKey: scoreKey)
            }
        }
        if let engine, engine.finalCards > 0, let round = series.roundID {
            showResultSplash = true
            if series.beginIntermission(round: round, now: Date().timeIntervalSinceReferenceDate) {
                nextGameIn = Int(MatchSeries.intermission)
            }
        }
        var saved = SavedSession(game: savedGame, series: series, white: whitePlayer, black: blackPlayer,
                                 hostModel: hostPlayer.model, language: language, useChatGPTLogin: useChatGPTLogin,
                                 camera: scene.cameraCheckpoint, hostProvider: hostPlayer.provider, gameMemory: gameMemory,
                                 claudeAccess: claudeAccess, personas: personas)
        saved.voiceProvider = voiceProvider
        saved.openAIVoice = openAIVoice
        saved.qwenVoice = qwenVoice
        saved.qwenPersonaVoices = qwenCasting.entries
        do {
            try sessionStore.save(saved)
            if saveFailed { persistenceError = nil; saveFailed = false }
        } catch {
            saveFailed = true
            persistenceError = "Автосохранение не удалось: проверьте свободное место и доступ к Application Support/ChessArena."
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 33_000_000) } catch { return }
                guard let self else { return }
                await self.tick()
            }
        }
    }

    func tone() {
        previewVoice(.host)
    }

    var canPreviewVoice: Bool { engine == nil && !matchRunning }

    func previewVoice(_ profile: VoiceProfile) {
        guard canPreviewVoice, previewProfile == nil else { return }
        let id = UUID()
        previewID = id
        previewProfile = profile
        voicePreview = Task {
            guard !Task.isCancelled, canPreviewVoice else { return }
            voice.language = language
            _ = await voice.speak(profile.previewText(language), kind: .tone, profile: profile)
            if previewID == id { previewProfile = nil; voicePreview = nil }
        }
    }

    func stopVoicePreview() {
        previewID = UUID()
        voicePreview?.cancel(); voicePreview = nil
        previewProfile = nil
        voice.stop()
    }

    func setQwenVoice(_ name: String, for persona: PlayerPersona) {
        qwenCasting.setVoice(name, for: persona)
    }

    func personaLabel(for player: PlayerConfiguration) -> String {
        personas.persona(provider: player.provider, model: player.model)?.displayName(language)
            ?? language.text("выберется при старте", "assigned at start")
    }

    var canContinueMatch: Bool {
        if let engine { return engine.paused && engine.referee.end == nil }
        return savedGame.map { $0.referee.end == nil } ?? false
    }

    func continueMatch() {
        if engine != nil { resume(); return }
        guard let checkpoint = savedGame, checkpoint.referee.end == nil else { return }
        guard validatePlayers(), let round = series.resumeRound() else { return }
        launchRound(round, restoring: checkpoint)
        startTicker()
    }

    func startNewGame() { startFreshGame(resetSeries: false) }
    func startNewSeries() { startFreshGame(resetSeries: true) }

    private func startFreshGame(resetSeries: Bool) {
        // Keep the current game intact if connection settings need attention.
        guard validatePlayers() else { return }
        stopMatch()
        savedGame = nil
        let round = resetSeries ? series.startNewSeries() : series.start()
        if let data = try? JSONEncoder().encode(series.score) {
            UserDefaults.standard.set(data, forKey: scoreKey)
        }
        launchRound(round)
        startTicker()
    }

    func stopMatch() {
        stopVoicePreview()
        series.stop()
        ticker?.cancel(); ticker = nil
        engine?.onStateChanged = nil
        engine?.onGameEnded = nil
        engine?.stop()
        if let engine { picture = engine.picture; savedGame = engine.checkpoint; gameMemory = engine.gameMemory }
        voice.stop()
        if let engine { finishArchive(engine) }
        engine = nil
        nextGameIn = nil
        paused = false
        matchRunning = false
        canRepeatRequest = false
        status = canContinueMatch
            ? language.text("Партия остановлена. Можно продолжить.", "Game stopped. You can continue.")
            : language.text("Серия остановлена", "Series stopped")
        saveState()
    }

    private func loadScore() {
        guard !matchRunning else { return }
        let saved = UserDefaults.standard.data(forKey: scoreKey)
            .flatMap { try? JSONDecoder().decode(SeriesScore.self, from: $0) } ?? SeriesScore()
        series = MatchSeries(score: saved)
    }

    private func launchRound(_ round: UUID, restoring saved: GameCheckpoint? = nil) {
        stopVoicePreview()
        showResultSplash = false
        savedGame = nil
        scene.resetBoard(position: saved?.referee.position ?? .standard())
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChessArena", isDirectory: true)
            .appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + round.uuidString + "-" + UUID().uuidString, isDirectory: true)
        let white = playerSeat(whitePlayer, side: .white)
        let black = playerSeat(blackPlayer, side: .black)
        let archive = MatchArchive(directory: folder, whiteName: white.name, blackName: black.name)
        let match = MatchEngine(
            scene: scene,
            voice: voice,
            transport: ArenaChatTransport(connection: useChatGPTLogin ? chatGPT : nil, gemini: gemini.cli, claude: claude.cli, lc0: lc0.transport),
            archive: archive,
            white: white,
            black: black,
            host: configuredHost,
            gameMemory: gameMemory
        )
        match.animationDuration = 1.2
        match.modelLog = modelLog
        match.language = language
        voice.language = language
        if let saved { match.restore(saved) }
        match.onStateChanged = { [weak self, weak match] in
            guard let self, let match, self.engine === match else { return }
            self.saveState()
        }
        match.onGameEnded = { [weak self, weak match] _ in
            guard let self, let match, self.engine === match else { return }
            self.saveState()
        }
        engine = match
        matchRunning = true
        startedAt = Date().addingTimeInterval(-(saved?.elapsed ?? 0))
        nextGameIn = series.remaining(at: Date().timeIntervalSinceReferenceDate)
        paused = false
        moveNumber = match.referee.position.fullmove
        canRepeatRequest = false
        picture = match.picture
        status = language.text("Партия идёт", "Match in progress")
        saveState()
        Task {
            guard self.engine === match else { return }
            do {
                try await match.start(at: saved?.elapsed ?? 0)
                guard self.engine === match else { return }
                self.picture = match.picture
                self.canRepeatRequest = match.canRepeatPlayerRequest
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

    func repeatPlayerRequest() {
        guard let engine, engine.canRepeatPlayerRequest else { return }
        engine.repeatPlayerRequest()
        picture = engine.picture
        paused = engine.paused
        canRepeatRequest = engine.canRepeatPlayerRequest
        status = language.text("Запрос игроку отправлен повторно", "Player request sent again")
    }

    func resume() {
        guard let engine, engine.paused else { return }
        guard validatePlayers() else { return }
        engine.white = playerSeat(whitePlayer, side: .white)
        engine.black = playerSeat(blackPlayer, side: .black)
        engine.host = configuredHost
        engine.resume()
        paused = false
        status = "Партия идёт"
    }

    var needsChatGPT: Bool {
        configurations.contains { $0.provider == .chatGPT }
    }

    var needsGemini: Bool { configurations.contains { $0.provider == .gemini } }
    var needsClaude: Bool { configurations.contains { $0.provider == .claude } }
    var needsLC0: Bool { [whitePlayer, blackPlayer].contains { $0.provider == .lc0 } }
    var needsDeepSeek: Bool { [whitePlayer, blackPlayer].contains { $0.provider == .deepseek } }
    private var keys: ProviderKeys { ProviderKeys(grok: grokKey, chatGPT: chatKey, anthropic: claudeKey, claudeAccess: claudeAccess, deepseek: deepSeekKey) }

    /// A player seat with its persona; first encounters draw a free persona and persist it with the session.
    private func playerSeat(_ player: PlayerConfiguration, side: Side) -> Seat {
        var seat = player.seat(side: side, keys: keys)
        let before = personas
        seat.persona = personas.assign(provider: player.provider, model: player.model)
        if personas != before { saveState() }
        return seat
    }

    func shutdown() {
        saveState()
        stopVoicePreview()
        voice.shutdown()
        gemini.cancel()
        claude.cancel()
        deepseek.cancel()
        lc0.cancel()
        GeminiCLI.cancelAll()
        ClaudeCLI.cancelAll()
    }

    var needsGrok: Bool {
        configurations.contains { $0.provider == .grok }
    }

    private var configurations: [PlayerConfiguration] { [whitePlayer, blackPlayer, hostPlayer] }

    private var configuredHost: Seat {
        var seat = hostPlayer.seat(side: .white, keys: keys)
        seat.name = "Host"
        return seat
    }

    func selectAvailableChatGPTModels() {
        guard useChatGPTLogin, let first = chatGPT.models.first else { return }
        if whitePlayer.provider == .chatGPT, !chatGPT.models.contains(where: { $0.id == whitePlayer.model }) {
            whitePlayer.model = first.id
        }
        if blackPlayer.provider == .chatGPT, !chatGPT.models.contains(where: { $0.id == blackPlayer.model }) {
            blackPlayer.model = first.id
        }
        if hostPlayer.provider == .chatGPT, !chatGPT.models.contains(where: { $0.id == hostPlayer.model }) {
            hostPlayer.model = first.id
        }
    }

    private func updatePlayerNames() {
        guard !restoring else { return }
        guard !matchRunning else { saveState(); return }
        picture.whiteName = whitePlayer.provider.rawValue
        picture.blackName = blackPlayer.provider.rawValue
        saveState()
    }

    private func validatePlayers() -> Bool {
        if needsLC0 {
            guard !lc0.busy else { status = "Дождитесь проверки LC0"; return false }
            do { try lc0.settings.validate() }
            catch { status = (error as? ChatError)?.userMessage ?? LC0Error.execution.userMessage; return false }
        }
        if needsDeepSeek, deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = "Введите API-ключ DeepSeek для выбранных игроков"; return false
        }
        if needsClaude {
            switch claudeAccess {
            case .apiKey:
                guard !claudeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    status = "Введите API-ключ Anthropic для Claude"; return false
                }
            case .subscription:
                guard !claude.busy else { status = "Дождитесь проверки Claude Code CLI"; return false }
                guard claude.cliVerified else {
                    status = "Проверьте подключение Claude по подписке в настройках"; return false
                }
            }
        }
        if needsGrok, grokKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = "Введите ключ xAI для выбранных участников Grok"; return false
        }
        if needsGemini {
            guard !gemini.busy else { status = "Дождитесь проверки Gemini"; return false }
            for player in configurations where player.provider == .gemini {
                guard gemini.verifiedModels.contains(player.model) else {
                    status = "Проверьте выбранную модель Gemini тестовым ходом в настройках"; return false
                }
            }
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
        for (name, player) in [("белых", whitePlayer), ("чёрных", blackPlayer), ("комментатора", hostPlayer)] {
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
            engine.white = playerSeat(whitePlayer, side: .white)
            engine.black = playerSeat(blackPlayer, side: .black)
            engine.host = configuredHost
        }
        await engine.advance(to: elapsed)
        guard self.engine === engine, series.running else { return }
        if let frame = scene.copyFrame() {
            engine.appendFrame(frame)
        }
        picture = engine.picture
        moveNumber = engine.referee.position.fullmove
        paused = engine.paused
        canRepeatRequest = engine.canRepeatPlayerRequest
        let now = Date().timeIntervalSinceReferenceDate
        nextGameIn = series.remaining(at: now)
        if let seconds = nextGameIn {
            status = language.text("Следующая партия через \(seconds) с", "Next game in \(seconds) s")
        } else if engine.phase == "summary" {
            status = language.text("Итоги партии · комментатор", "Post-game commentary")
        } else if engine.phase == "learning" {
            status = language.text("Игроки сохраняют планы на следующую партию…", "Players are saving plans for the next game…")
        } else if engine.phase == "preparing" {
            status = language.text("Ход получен · готовим озвучку и ждём окончания текущей реплики…", "Move received · preparing audio and waiting for the current utterance…")
        } else if engine.paused {
            status = engine.pauseReason ?? language.text("Автоматический повтор запроса…", "Retrying automatically…")
        } else {
            status = language.text("Партия идёт", "Match in progress")
        }
        if let round = series.nextRoundIfDue(at: now) {
            engine.onStateChanged = nil
            engine.onGameEnded = nil
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
