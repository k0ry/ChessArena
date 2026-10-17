import CoreVideo
import Foundation

@MainActor
public final class MatchEngine {
    public let scene: BoardScene
    public let voice: Voice
    public let transport: ChatTransport
    public let archive: MatchArchive
    public var white: Seat
    public var black: Seat
    public var host: Seat
    public var animationDuration: TimeInterval = 0
    public var language: BroadcastLanguage = .english
    public var modelLog: ModelLog?
    private var playerLogID: UUID?
    public var requestTimeout: TimeInterval = RequestTimeouts.player
    public var hostTimeout: TimeInterval = RequestTimeouts.host
    public var learningTimeout: TimeInterval = RequestTimeouts.host
    public private(set) var gameMemory: GameMemory
    public var onStateChanged: (() -> Void)?
    private var lastCheckpoint: GameCheckpoint?
    public var onGameEnded: ((GameEnd) -> Void)?
    public private(set) var retryAt: TimeInterval?
    private var retryCount = 0
    private var stopped = false
    private var auxiliaryTasks: [UUID: Task<Void, Never>] = [:]
    private var turnTasks: [Int: Task<Void, Never>] = [:]

    public private(set) var referee = Referee()
    public private(set) var director = ChronicleDirector()
    public private(set) var speech: [SpokenLine] = []
    /// Player taunts spoken by their persona voices; kept apart from the host's speech log.
    public private(set) var spokenTaunts: [SpokenLine] = []
    public private(set) var picture: BroadcastPicture
    public private(set) var phase = "idle"
    public private(set) var clock: TimeInterval = 0
    public private(set) var moveRequestCount = 0
    public private(set) var boardVersion = 0
    public private(set) var finalCards = 0
    public private(set) var paused = false
    public private(set) var pauseReason: String?
    public private(set) var hostBoardVersions: [Int] = []
    public var onPlayerWaiting: (() -> Void)?

    private var thinkTask: Task<Void, Never>?
    private var lastPlayerRequest: (call: ChatCall, boardVersion: Int, side: Side)?
    private var thinkGeneration = 0
    private var waitEpoch = 0
    private var thinkStarted: TimeInterval = 0
    private var thinkDeadline: TimeInterval = 0
    private var waitSpoken = false
    private var lastRejection: String?
    private var whiteSelfNotes: String?
    private var blackSelfNotes: String?
    private var animatingUntil: TimeInterval?
    private var started = false
    private var restored = false
    private var sawFinal = false
    private var replies: [ModelReply] = []
    private var hostCommentaryCount = 0

    public init(scene: BoardScene, voice: Voice, transport: ChatTransport, archive: MatchArchive, white: Seat, black: Seat, host: Seat, gameMemory: GameMemory = GameMemory()) {
        self.scene = scene
        self.voice = voice
        self.transport = transport
        self.archive = archive
        self.white = white
        self.black = black
        self.host = host
        self.gameMemory = gameMemory
        picture = BroadcastPicture(
            whiteName: white.name,
            blackName: black.name,
            clockText: "00:00",
            line: "",
            taunt: "",
            banner: nil
        )
    }

    public var checkpoint: GameCheckpoint {
        GameCheckpoint(referee: referee, elapsed: floor(clock), picture: picture,
                       lastRejection: lastRejection, requestCount: moveRequestCount, journal: archive.journal,
                       whiteSelfNotes: whiteSelfNotes, blackSelfNotes: blackSelfNotes, gameMemory: gameMemory)
    }

    /// A pending network call is recreated from the restored position, never replayed as a move.
    public func restore(_ saved: GameCheckpoint) {
        precondition(!started)
        restored = true
        referee = saved.referee
        clock = saved.elapsed
        picture = saved.picture
        picture.thinkingSide = nil
        picture.thinkingSelfNotes = nil
        picture.pausedPlayer = nil
        replies = saved.picture.replies
        hostCommentaryCount = saved.journal.filter { $0.kind != "taunt" }.count
        lastRejection = saved.lastRejection
        whiteSelfNotes = saved.whiteSelfNotes
        blackSelfNotes = saved.blackSelfNotes
        gameMemory = saved.gameMemory ?? gameMemory
        moveRequestCount = saved.requestCount
        boardVersion = referee.accepted.count
        archive.restore(moves: referee.accepted, journal: saved.journal, end: referee.end)
        scene.show(position: referee.position)
    }

    public func toneTest() async -> SpokenLine {
        voice.language = language
        let line = SpokenLine(kind: .tone, text: language.toneTest, boardVersion: boardVersion, clock: clock)
        _ = await voice.speak(line.text, kind: .tone, profile: .host)
        speech.append(line)
        return line
    }

    public func start(at time: TimeInterval) async throws {
        guard !started else { return }
        started = true
        clock = time
        try archive.open()
        archive.append(pixelBuffer: FrameBuffer.make())
        scene.show(position: referee.position)
        if let end = referee.end {
            // The runtime restores the original intermission deadline and already-recorded score.
            director.gameOver = true
            _ = director.advance(to: time)
            sawFinal = true
            phase = "final"
            refreshPicture(banner: language.result(end, white: white.name, black: black.name))
        } else {
            refreshPicture()
            if !restored, referee.accepted.isEmpty {
                await speak(greeting, kind: .intro)
                guard !stopped else { return }
            }
            beginThink()
        }
    }

    /// Spoken once per new game by the host, without a model request so the start never waits on the network.
    var greeting: String {
        func lineup(_ seat: Seat, _ side: Side) -> String {
            let persona = seat.persona.map { language.text(", в образе \($0.displayName(language))", ", in the manner of \($0.displayName(language))") } ?? ""
            return language.text(
                "\(side == .white ? "Белыми" : "Чёрными") играет \(seat.name), модель \(seat.model)\(persona).",
                "Playing \(side == .white ? "White" : "Black"): \(seat.name), model \(seat.model)\(persona).")
        }
        return language.text("Добрый вечер, дамы и господа! Добро пожаловать на Chess Arena!", "Good evening, ladies and gentlemen, and welcome to Chess Arena!")
            + " " + lineup(white, .white) + " " + lineup(black, .black) + " "
            + language.text("Партия начинается!", "Let the game begin!")
    }

    public func advance(to time: TimeInterval) async {
        guard !stopped else { return }
        clock = time
        if let retryAt, time >= retryAt { resume() }
        if let until = animatingUntil, time >= until {
            animatingUntil = nil
            scene.finishAnimation()
        }
        let cues = director.advance(to: time)
        for cue in cues {
            await handle(cue)
        }
        maybeWaitLine()
        refreshPicture()
    }

    public func resume() {
        guard !stopped, paused, referee.end == nil else { return }
        paused = false
        retryAt = nil
        pauseReason = nil
        phase = "thinking"
        beginThink()
    }

    public var canRepeatPlayerRequest: Bool {
        guard started, !stopped, referee.end == nil, thinkTask != nil || paused,
              let request = lastPlayerRequest else { return false }
        return request.boardVersion == boardVersion && request.side == referee.position.sideToMove
    }

    public func repeatPlayerRequest() {
        guard canRepeatPlayerRequest, let request = lastPlayerRequest else { return }
        // Invalidate the old attempt before cancelling it: a late reply must not move a piece.
        thinkGeneration += 1
        waitEpoch += 1
        thinkTask?.cancel()
        thinkTask = nil
        auxiliaryTasks.values.forEach { $0.cancel() }
        auxiliaryTasks.removeAll()
        voice.stop()
        paused = false
        pauseReason = nil
        retryAt = nil
        retryCount = 0
        beginThink(repeating: request.call)
    }

    public func stop() {
        stopped = true
        thinkGeneration += 1
        waitEpoch += 1
        thinkTask?.cancel(); thinkTask = nil
        auxiliaryTasks.values.forEach { $0.cancel() }; auxiliaryTasks.removeAll()
        turnTasks.values.forEach { $0.cancel() }; turnTasks.removeAll()
        retryAt = nil; paused = false
        scene.setThinking(nil)
        voice.stop()
        refreshPicture()
    }

    public func appendFrame(_ buffer: CVPixelBuffer) {
        guard archive.isOpen else { return }
        archive.append(pixelBuffer: buffer)
    }

    public func closeArchive() async throws {
        try await archive.finish(end: referee.end)
    }

    private func beginThink(repeating request: ChatCall? = nil) {
        guard !stopped, thinkTask == nil, referee.end == nil, !paused, !finalActive else { return }
        thinkGeneration += 1
        let generation = thinkGeneration
        thinkStarted = clock
        thinkDeadline = clock + requestTimeout
        waitSpoken = false
        phase = "thinking"
        scene.setThinking(referee.position.sideToMove)
        let call = request ?? playerCall()
        lastPlayerRequest = (call, boardVersion, referee.position.sideToMove)
        moveRequestCount += 1
        thinkTask = Task { [weak self] in
            guard let self else { return }
            defer { self.turnTasks.removeValue(forKey: generation) }
            guard !Task.isCancelled, generation == self.thinkGeneration else { return }
            do {
                let side = self.referee.position.sideToMove
                let player = side == .white ? self.white.name : self.black.name
                let text = try await self.complete(call, context: "Ход \(side == .white ? "белых" : "чёрных") · \(player)", timeout: self.requestTimeout, player: true)
                guard !Task.isCancelled, !self.stopped else { return }
                self.onPlayerWaiting?()
                await self.ingest(text, generation: generation)
            } catch is CancellationError {
                return
            } catch let error as ChatError where error == .unreadable {
                self.onPlayerWaiting?()
                await self.ingest("", generation: generation)
            } catch {
                self.onPlayerWaiting?()
                await self.stall(generation: generation, error: error as? ChatError ?? .transport)
            }
        }
        turnTasks[generation] = thinkTask
        refreshPicture()
    }

    private func ingest(_ text: String, generation: Int) async {
        guard !stopped, generation == thinkGeneration else { return }
        thinkTask = nil
        waitEpoch += 1
        scene.setThinking(nil)
        picture.thinkingSide = nil
        picture.thinkingSelfNotes = nil
        let side = referee.position.sideToMove
        let seat = side == .white ? white : black
        noteReply(side: side, name: seat.name, text: text)
        let intent = ChatParser.moveIntent(from: text)
        let submission = referee.submit(rawMove: intent?.move ?? text, taunt: intent?.taunt ?? "")
        switch submission {
        case .accepted(let move, let end):
            if let notes = intent?.selfNotes {
                if side == .white { whiteSelfNotes = notes } else { blackSelfNotes = notes }
            }
            lastRejection = nil
            retryCount = 0
            boardVersion += 1
            scene.animate(
                move: move.move,
                positionAfter: referee.position,
                side: mover(of: move),
                duration: animationDuration
            )
            if animationDuration > 0 {
                animatingUntil = clock + animationDuration
                phase = "animating"
            }
            picture.taunt = move.taunt
            picture.tauntSide = side
            picture.tauntPersona = seat.persona?.displayName(language)
            archive.record(move: move, clock: clock)
            refreshPicture()
            if let end {
                await finishGame(end)
            } else {
                let commentary = await hostText(Prompts.moveCommentary(fen: referee.position.fen, san: move.san), trackBoard: true)
                guard !stopped else { return }
                await speak(commentary, kind: .move)
                guard !stopped else { return }
                speakTaunt(move.taunt, by: seat)
                beginThink()
            }
        case .rejected(let reason, _):
            if let playerLogID { modelLog?.rejectMove(playerLogID, reason: reason, secrets: [seat.apiKey]) }
            lastRejection = reason
            beginThink()
        case .resigned(let end):
            if let playerLogID {
                modelLog?.rejectMove(playerLogID, reason: "Три недопустимых ответа подряд; засчитано поражение.", secrets: [seat.apiKey])
            }
            await finishGame(end)
        case .ignored:
            break
        }
    }

    private func stall(generation: Int, error: ChatError) async {
        guard !stopped, generation == thinkGeneration else { return }
        thinkTask = nil
        waitEpoch += 1
        paused = true
        phase = "paused"
        scene.setThinking(nil)
        let side = referee.position.sideToMove
        let seat = side == .white ? white : black
        if error.pausesWithoutRetry {
            retryAt = nil
            pauseReason = "\(seat.name): \(error.userMessage)"
            picture.line = pauseReason ?? ""
            refreshPicture()
            return
        }
        retryCount += 1
        let delay = min(60.0, 3 * pow(2, Double(min(retryCount - 1, 5))))
        retryAt = clock + delay
        pauseReason = "\(seat.name): \(error.userMessage) " + language.text("Автоповтор через \(Int(delay)) с.", "Retrying in \(Int(delay)) s.")
        picture.line = language.text("\(seat.name): повторяем запрос хода…", "\(seat.name): retrying the move request…")
        refreshPicture()
    }

    private func maybeWaitLine() {
        guard phase == "thinking", !waitSpoken, clock - thinkStarted >= 20, thinkTask != nil else { return }
        waitSpoken = true
        let epoch = waitEpoch
        let side = referee.position.sideToMove
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.auxiliaryTasks.removeValue(forKey: taskID) }
            let text = await self.hostText(Prompts.waiting(side: side), trackBoard: false)
            guard epoch == self.waitEpoch, self.phase == "thinking" else { return }
            await self.speak(text, kind: .wait)
        }
        auxiliaryTasks[taskID] = task
    }

    private func handle(_ cue: ChronicleDirector.Cue) async {
        switch cue {
        case .startFinal:
            guard !sawFinal else { return }
            sawFinal = true
            finalCards += 1
            phase = "final"
            let moves = referee.accepted.map(\.move)
            let sides = moves.indices.map { $0.isMultiple(of: 2) ? Side.white : Side.black }
            scene.layChronicle(moves: moves, sides: sides)
            let title = referee.end.map { language.result($0, white: white.name, black: black.name) } ?? "GAME OVER"
            refreshPicture(banner: title)
        case .endFinal:
            phase = "finished"
            refreshPicture()
        }
    }

    private func finishGame(_ end: GameEnd) async {
        thinkTask?.cancel()
        thinkTask = nil
        archive.markResult(end)
        onGameEnded?(end)
        phase = "summary"
        refreshPicture(line: language.text("Комментатор подводит итоги партии…", "The commentator is preparing the verdict…"))
        let title = language.result(end, white: white.name, black: black.name)
        let reviewResult: String
        if case .resignation = end {
            reviewResult = title + " · " + end.title + " (three consecutive invalid move replies)"
        } else {
            reviewResult = title + " · " + end.title
        }
        async let whiteAdvice: Void = prepareNextGame(for: white, result: reviewResult)
        async let blackAdvice: Void = prepareNextGame(for: black, result: reviewResult)
        let summary = await hostText(Prompts.final(title: title, moves: referee.accepted.map(\.san)), trackBoard: false)
        guard !stopped, !Task.isCancelled else { return }
        await speak(summary, kind: .final)
        guard !stopped, !Task.isCancelled else { return }
        phase = "learning"
        refreshPicture()
        _ = await (whiteAdvice, blackAdvice)
        guard !stopped, !Task.isCancelled else { return }
        director.gameOver = true
        await advance(to: clock)
    }

    private func prepareNextGame(for seat: Seat, result: String) async {
        guard !stopped, !Task.isCancelled else { return }
        let prompt = Prompts.nextGameAdvice(side: seat.side, result: result,
                                           fen: referee.position.fen, moves: referee.accepted.map(\.san))
        let call = ChatCall(url: seat.completionsURL, apiKey: seat.apiKey, model: seat.model,
                            system: language.prompt(prompt.system), user: prompt.user,
                            selfNotes: seat.side == .white ? whiteSelfNotes : blackSelfNotes,
                            route: seat.route, gameAdvice: gameMemory.advice(for: seat), effort: "high")
        do {
            let text = try await complete(call, context: "План на следующую партию · \(seat.side == .white ? "белые" : "чёрные") · \(seat.name)", timeout: learningTimeout)
            guard !stopped, !Task.isCancelled else { return }
            gameMemory.remember(text, for: seat, secrets: [white.apiKey, black.apiKey, host.apiKey])
            refreshPicture()
        } catch {
            // The model log records the error; retain the last successful plan and let the series continue.
        }
    }

    private func speak(_ text: String, kind: SpeechKind) async {
        let spoken = SpokenText.clean(text)
        guard !stopped, !Task.isCancelled, !spoken.isEmpty else { return }
        picture.line = spoken
        refreshPicture()
        voice.language = language
        let samples: [Int16]
        do {
            samples = try await RequestDeadline.run(seconds: 20) { [voice] in
                await voice.speak(spoken, kind: kind, profile: .host)
            }
        } catch {
            voice.stop()
            samples = []
        }
        guard !stopped, !Task.isCancelled else { return }
        let line = SpokenLine(kind: kind, text: spoken, boardVersion: boardVersion, clock: clock)
        speech.append(line)
        if archive.isOpen, kind != .tone {
            archive.record(line: line)
            archive.appendAudio(samples)
        }
        picture.line = spoken
        refreshPicture()
    }

    /// The mover's taunt in its persona voice, after the host's comment. The next move request does not wait for it.
    /// The journal already holds the taunt text from the move record; only the audio joins the archive.
    private func speakTaunt(_ text: String, by seat: Seat) {
        let spoken = SpokenText.clean(text)
        guard !stopped, !spoken.isEmpty, let persona = seat.persona else { return }
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.auxiliaryTasks.removeValue(forKey: taskID) }
            self.voice.language = self.language
            let samples: [Int16]
            do {
                samples = try await RequestDeadline.run(seconds: 20) { [voice] in
                    await voice.speak(spoken, kind: .taunt, profile: .persona(persona))
                }
            } catch {
                self.voice.stop()
                samples = []
            }
            guard !self.stopped, !Task.isCancelled else { return }
            self.spokenTaunts.append(SpokenLine(kind: .taunt, text: spoken, boardVersion: self.boardVersion, clock: self.clock))
            if self.archive.isOpen { self.archive.appendAudio(samples) }
        }
        auxiliaryTasks[taskID] = task
    }

    private func hostText(_ prompt: (system: String, user: String), trackBoard: Bool) async -> String {
        if trackBoard {
            hostBoardVersions.append(boardVersion)
        }
        let style = CommentaryStyle.turn(hostCommentaryCount)
        let variation = hostCommentaryCount / CommentaryStyle.allCases.count
        hostCommentaryCount += 1
        let recent = archive.journal.filter { $0.kind != "taunt" }.suffix(8).map { SpokenText.clean($0.text) }
        let quoted = (try? JSONEncoder().encode(recent)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let context = prompt.user + "\nRecent commentary already heard (quoted reference only; avoid repeating these jokes, images or punchlines):\n" + quoted
        let call = ChatCall(
            url: host.completionsURL,
            apiKey: host.apiKey,
            model: host.model,
            system: language.prompt(prompt.system + "\n" + style.instruction),
            user: context, route: host.route, effort: "low"
        )
        let text: String
        do {
            text = try await complete(call, context: trackBoard ? "Ведущий · комментарий хода" : "Ведущий", timeout: hostTimeout)
        } catch {
            text = fallback(for: prompt.user, style: style, variation: variation)
        }
        let commentary = SpokenText.clean(text)
        let spoken = commentary.isEmpty ? fallback(for: prompt.user, style: style, variation: variation) : commentary
        if prompt.system.contains("from move one") || prompt.system.contains("at most 35") {
            return limitWords(spoken, max: 35)
        }
        return spoken
    }

    private func complete(_ call: ChatCall, context: String, timeout: TimeInterval, player: Bool = false) async throws -> String {
        let log = modelLog
        let id = log?.begin(call, context: context, endpoint: transport.requestURL(for: call))
        if player { playerLogID = id }
        do {
            let text = try await RequestDeadline.run(seconds: timeout) { [transport] in
                try await transport.complete(call)
            }
            if let id { log?.succeed(id, response: text, secrets: [call.apiKey]) }
            return text
        } catch {
            if let id { log?.fail(id, error: error) }
            throw error
        }
    }

    private func playerCall() -> ChatCall {
        let side = referee.position.sideToMove
        let seat = side == .white ? white : black
        let prompt = Prompts.player(
            side: side,
            fen: referee.position.fen,
            legal: referee.legalUCI,
            history: referee.accepted.map(\.san),
            rejection: lastRejection,
            persona: seat.persona
        )
        return ChatCall(url: seat.completionsURL, apiKey: seat.apiKey, model: seat.model,
                        system: language.prompt(prompt.system), user: prompt.user,
                        selfNotes: side == .white ? whiteSelfNotes : blackSelfNotes, route: seat.route,
                        gameAdvice: gameMemory.advice(for: seat), effort: "high")
    }

    private func fallback(for user: String, style: CommentaryStyle, variation: Int) -> String {
        let event: CommentaryStyle.Event
        if user.contains("still thinking") { event = .waiting }
        else if user.contains("resigns") { event = .resignation }
        else if user.contains("stalled") { event = .stall }
        else if user.contains("Result:") { event = .final }
        else { event = .move }
        let joke = style.fallback(for: event, language: language, variation: variation)
        guard event == .final else { return joke }
        let result = referee.end.map { language.result($0, white: white.name, black: black.name) }
            ?? language.text("Партия завершена", "Game over")
        return result + ". " + joke
    }

    private func noteReply(side: Side, name: String, text: String) {
        replies.append(ModelReply(id: replies.count + 1, side: side, name: name, text: text))
        picture.replies = replies
    }

    private func refreshPicture(line: String? = nil, banner: String? = nil) {
        let thinkingSide = phase == "thinking" && thinkTask != nil ? referee.position.sideToMove : nil
        // Whole seconds so the checkpoint changes once a second, not once a frame.
        let secondsLeft = thinkingSide == nil ? nil : max(0, Int((thinkDeadline - clock).rounded(.up)))
        // Broadcast only this game's turn note; cross-game advice stays in the model request.
        let notes = thinkingSide == nil ? nil : lastPlayerRequest?.call.selfNotes
        picture = BroadcastPicture(
            whiteName: white.name,
            blackName: black.name,
            clockText: ClockFormat.string(clock),
            line: line ?? picture.line,
            taunt: picture.taunt,
            banner: banner ?? picture.banner,
            replies: replies,
            thinkingSide: thinkingSide,
            pausedPlayer: paused ? (referee.position.sideToMove == .white ? white.name : black.name) : nil,
            thinkingSelfNotes: notes.map { ModelLog.sanitize($0, secrets: [white.apiKey, black.apiKey, host.apiKey]) },
            tauntSide: picture.tauntSide,
            tauntPersona: picture.tauntPersona,
            thinkSecondsLeft: secondsLeft
        )
        let saved = checkpoint
        if saved != lastCheckpoint {
            lastCheckpoint = saved
            onStateChanged?()
        }
    }

    private var finalActive: Bool {
        if case .finalCard = director.phase { return true }
        return false
    }

    private func mover(of move: AcceptedMove) -> Side {
        let ply = referee.accepted.count
        return ply % 2 == 1 ? .white : .black
    }
}
