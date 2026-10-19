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
    private var requestDiagnostic: MatchDiagnostic?
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
    private var requestTiming: RequestTiming?
    var requestNow: @Sendable () -> TimeInterval = { RequestTiming.monotonicNow() }
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
    // One draw per board position, retained across rejected answers and network retries.
    var tauntDraw: () -> Int = { Int.random(in: 0..<100) }
    private var tauntDecision: (version: Int, allowed: Bool)?
    private let presentationGate = SpeechGate()
    private var archiveOrigin: TimeInterval = 0
    private var airingAudio: (samples: [Int16], start: TimeInterval, written: Int)?

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
        if referee.end == nil { picture.banner = nil }
        picture.tauntPersona = nil
        picture.clearPendingRequest(language: language)
        replies = saved.picture.replies
        hostCommentaryCount = saved.journal.filter { $0.kind != "taunt" }.count
        lastRejection = saved.lastRejection
        whiteSelfNotes = saved.whiteSelfNotes
        blackSelfNotes = saved.blackSelfNotes
        gameMemory = saved.gameMemory ?? gameMemory
        moveRequestCount = saved.requestCount
        boardVersion = referee.accepted.count
        archive.restore(moves: referee.accepted, journal: saved.journal, end: referee.end, position: referee.position)
        scene.resetBoard(position: referee.position)
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
        archiveOrigin = time
        try archive.open()
        try archive.writeParticipants(white: white, black: black)
        archive.append(pixelBuffer: FrameBuffer.make())
        scene.resetBoard(position: referee.position)
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
            return language.text(
                "\(side == .white ? "Белыми" : "Чёрными") играет \(seat.name), модель \(seat.model).",
                "Playing \(side == .white ? "White" : "Black"): \(seat.name), model \(seat.model).")
        }
        return language.text("Добрый вечер, дамы и господа! Добро пожаловать на Chess Arena!", "Good evening, ladies and gentlemen, and welcome to Chess Arena!")
            + " " + lineup(white, .white) + " " + lineup(black, .black) + " "
            + language.text("Партия начинается!", "Let the game begin!")
    }

    public func advance(to time: TimeInterval) async {
        guard !stopped else { return }
        clock = time
        if let retryAt, time >= retryAt { resume(resetAttempts: false) }
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

    public func resume(resetAttempts: Bool = true) {
        guard !stopped, paused, referee.end == nil else { return }
        if resetAttempts { retryCount = 0 }
        paused = false
        retryAt = nil
        pauseReason = nil
        phase = "thinking"
        picture.line = language.text("Ожидаем ответ модели.", "Waiting for the model response.")
        beginThink()
    }

    public var canRepeatPlayerRequest: Bool {
        guard started, !stopped, referee.end == nil, thinkTask != nil || paused,
              let request = lastPlayerRequest else { return false }
        return request.boardVersion == boardVersion && request.side == referee.position.sideToMove
    }

    public func repeatPlayerRequest() {
        guard canRepeatPlayerRequest else { return }
        let wasPaused = paused
        // Invalidate the old attempt before cancelling it: a late reply must not move a piece.
        thinkGeneration += 1
        waitEpoch += 1
        thinkTask?.cancel()
        thinkTask = nil
        // A repeated player request does not interrupt an already airing commentary.
        paused = false
        pauseReason = nil
        retryAt = nil
        retryCount = 0
        if wasPaused { picture.line = language.text("Ожидаем ответ модели.", "Waiting for the model response.") }
        beginThink()
    }

    public func stop() {
        emitDiagnostic("stopped")
        flushAiringAudio()
        airingAudio = nil
        stopped = true
        thinkGeneration += 1
        waitEpoch += 1
        thinkTask?.cancel(); thinkTask = nil
        auxiliaryTasks.values.forEach { $0.cancel() }; auxiliaryTasks.removeAll()
        turnTasks.values.forEach { $0.cancel() }; turnTasks.removeAll()
        presentationGate.cancelPending()
        retryAt = nil; paused = false
        scene.setThinking(nil)
        voice.stop()
        refreshPicture()
    }

    public func appendFrame(_ buffer: CVPixelBuffer) {
        guard archive.isOpen else { return }
        flushAiringAudio()
        // Keep both writer inputs progressing even during thinking and synthesis.
        archive.appendSilence(until: max(0, clock - archiveOrigin))
        archive.append(pixelBuffer: buffer, at: max(0, clock - archiveOrigin))
    }

    private func flushAiringAudio(completed: Bool = false) {
        guard var audio = airingAudio, archive.isOpen else { return }
        let count = completed ? audio.samples.count
            : min(audio.samples.count, max(0, Int((clock - audio.start) * 44_100)))
        guard count > audio.written else { return }
        archive.appendAudio(Array(audio.samples[audio.written..<count]),
                            at: max(0, audio.start - archiveOrigin) + Double(audio.written) / 44_100)
        audio.written = count
        airingAudio = audio
    }

    public func closeArchive() async throws {
        try await archive.finish(end: referee.end, position: referee.position)
    }

    private func beginThink() {
        guard !stopped, thinkTask == nil, referee.end == nil, !paused, !finalActive else { return }
        thinkGeneration += 1
        let generation = thinkGeneration
        thinkStarted = clock
        waitSpoken = false
        phase = "thinking"
        scene.setThinking(referee.position.sideToMove)
        let call = playerCall()
        let timing = RequestTiming(seconds: min(requestTimeout, transport.requestTimeout(for: call) ?? requestTimeout), now: requestNow)
        requestTiming = timing
        lastPlayerRequest = (call, boardVersion, referee.position.sideToMove)
        moveRequestCount += 1
        requestDiagnostic = MatchDiagnostic(roundID: archive.roundID, requestID: UUID(), event: "request",
            provider: DeepSeekAPI.redact(referee.position.sideToMove == .white ? white.name : black.name, key: call.apiKey), model: DeepSeekAPI.redact(call.model, key: call.apiKey), side: referee.position.sideToMove,
            ply: boardVersion, fen: referee.position.fen, attempt: retryCount + 1,
            budget: call.route == .deepseek ? (call.maxOutputTokens ?? DeepSeekAPI.maxTokens) : nil)
        requestDiagnostic?.logicalTurnID = "\(archive.roundID.uuidString):\(boardVersion)"
        requestDiagnostic?.timeoutSeconds = timing.budget
        emitDiagnostic("request")
        thinkTask = Task { [weak self] in
            guard let self else { return }
            defer { self.turnTasks.removeValue(forKey: generation) }
            guard !Task.isCancelled, generation == self.thinkGeneration else { return }
            do {
                let side = self.referee.position.sideToMove
                let player = side == .white ? self.white.name : self.black.name
                let text = try await ResponseTrace.$receive.withValue({ [weak self] metadata in
                    await self?.recordResponse(metadata, generation: generation)
                }) {
                    try await self.complete(call, context: "Ход \(side == .white ? "белых" : "чёрных") · \(player)", timeout: timing.budget, player: true, timing: timing)
                }
                guard !Task.isCancelled, !self.stopped else { return }
                guard generation == self.thinkGeneration else { return }
                self.emitDiagnostic("response_received")
                self.onPlayerWaiting?()
                await self.ingest(text, generation: generation)
            } catch is CancellationError {
                return
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
        waitEpoch += 1
        phase = "preparing"
        refreshPicture()
        let side = referee.position.sideToMove
        let seat = side == .white ? white : black
        guard let intent = ChatParser.moveIntent(from: text) else {
            await stall(generation: generation, error: .response(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .schema))
            return
        }
        // Validate off-screen. The saved/live board advances only when its audio is ready to air.
        var candidate = referee
        let rawMove = intent.move
        let move = referee.position.parseUCI(rawMove)
        let important = move.map { referee.position.isLegal($0) && BanterPolicy.isImportant($0, in: referee.position) } ?? false
        let proposed = SpokenText.clean(intent.taunt)
        let recent = archive.journal.suffix(12).map(\.text)
        let allowed = (tauntDecision?.allowed ?? false) || important
        let taunt = allowed && !BanterPolicy.repeats(proposed, recent: recent) ? proposed : ""
        let submission = candidate.submit(rawMove: rawMove, taunt: taunt)
        switch submission {
        case .accepted(let move, let end):
            refreshPicture()
            let nextVersion = boardVersion + 1
            // The player's line can render while the host is still composing its response.
            async let tauntWork = prepareTaunt(move.taunt, by: seat)
            let commentary: String
            if let end {
                let title = language.result(end, white: white.name, black: black.name)
                commentary = await hostText(Prompts.final(title: title, moves: candidate.accepted.map(\.san)), trackBoard: false)
            } else {
                commentary = await hostText(Prompts.moveCommentary(fen: candidate.position.fen, san: move.san),
                                            trackBoard: true, version: nextVersion)
            }
            guard validTurn(generation) else { return }
            voice.language = language
            let prepared = await voice.prepare(commentary, kind: end == nil ? .move : .final, profile: .host)
            guard validTurn(generation) else { return }
            let taunt = await tauntWork
            guard validTurn(generation), await presentationGate.acquire() else { return }
            defer { presentationGate.release() }
            guard validTurn(generation) else { return }
            // The previous utterance and animation are finished. Commit exactly once.
            thinkTask = nil
            referee = candidate
            noteReply(side: side, name: seat.name, text: text, taunt: move.taunt)
            if let notes = intent.selfNotes {
                if side == .white { whiteSelfNotes = notes } else { blackSelfNotes = notes }
            }
            lastRejection = nil; retryCount = 0
            boardVersion = nextVersion
            scene.setThinking(nil)
            picture.taunt = move.taunt
            picture.tauntSide = side
            picture.tauntPersona = nil
            archive.record(move: move, clock: clock, includeTaunt: taunt == nil)
            emitDiagnostic("accepted", reason: move.move.uci)
            let presentMove = { [self] in
                scene.animate(move: move.move, positionAfter: candidate.position, side: side, duration: animationDuration)
                if animationDuration > 0 { animatingUntil = clock + animationDuration }
                phase = end == nil ? "animating" : "summary"
                refreshPicture()
                // The opponent may request/prepare its next turn while this turn is on air.
                if end == nil { beginThink() }
            }
            if let end {
                await finishGame(end, preparedSummary: prepared, preparedTaunt: taunt, onStart: presentMove)
            } else {
                if let taunt {
                    await playPrepared(taunt, version: nextVersion, move: move.move.uci, onStart: presentMove)
                    guard !stopped, !Task.isCancelled else { return }
                    await playPrepared(prepared, version: nextVersion)
                } else {
                    await playPrepared(prepared, version: nextVersion, onStart: presentMove)
                }
                guard !stopped, !Task.isCancelled else { return }
                await waitForAnimation()
            }
        case .rejected(let reason, _):
            thinkTask = nil
            referee = candidate
            noteReply(side: side, name: seat.name, text: text, taunt: "")
            if let playerLogID { modelLog?.rejectMove(playerLogID, reason: reason, secrets: [seat.apiKey]) }
            lastRejection = reason
            await stall(generation: generation, error: .response(.illegalMove))
        case .ignored:
            thinkTask = nil
        }
    }

    private func recordResponse(_ metadata: ResponseMetadata, generation: Int) {
        guard generation == thinkGeneration, !stopped, !Task.isCancelled else { return }
        requestDiagnostic?.response = metadata
        if let playerLogID { modelLog?.metadata(playerLogID, response: metadata) }
        emitDiagnostic("response")
    }

    private func emitDiagnostic(_ event: String, reason: String? = nil) {
        guard var entry = requestDiagnostic else { return }
        entry.event = event
        entry.reason = reason
        if ["accepted", "finished", "stopped"].contains(event) {
            entry.fen = referee.position.fen; entry.ply = boardVersion
        }
        let now = Date()
        entry.duration = requestTiming?.elapsed ?? max(0, now.timeIntervalSince(entry.timestamp))
        entry.timestamp = now
        entry.retryAt = retryAt
        archive.record(diagnostic: entry)
    }

    private func validTurn(_ generation: Int) -> Bool {
        !stopped && !Task.isCancelled && generation == thinkGeneration
    }

    private func prepareTaunt(_ text: String, by seat: Seat) async -> PreparedSpeech? {
        let text = SpokenText.clean(text)
        guard !text.isEmpty, let persona = seat.persona, !Task.isCancelled else { return nil }
        voice.language = language
        return await voice.prepare(text, kind: .taunt, profile: .persona(persona))
    }

    private func waitForAnimation() async {
        while animatingUntil != nil, !stopped, !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return }
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
        retryCount += 1
        if let playerLogID { modelLog?.rejectMove(playerLogID, reason: error.userMessage) }
        if case .response = error { lastRejection = error.userMessage }
        if error == .unreadable { lastRejection = error.userMessage }
        requestDiagnostic?.timeoutSource = error.timeoutSource(deadlineExpired: requestTiming?.remaining == 0)
        if error.pausesWithoutRetry || retryCount >= 3 {
            retryAt = nil
            requestDiagnostic?.retryDecision = error.pausesWithoutRetry ? "user_action_required" : "attempts_exhausted"
            emitDiagnostic("paused", reason: error.diagnosticCode)
            let exhausted = retryCount >= 3 && !error.pausesWithoutRetry
                ? language.text(" Три попытки исчерпаны. Нажмите «Повторить запрос».", " Three attempts exhausted. Repeat the request to continue.") : ""
            pauseReason = "\(seat.name): \(error.userMessage)" + exhausted
            picture.line = pauseReason ?? ""
            refreshPicture()
            return
        }
        // At most two corrective replies; automatic retries retain the batch counter.
        if error == .unreadable || { if case .response = error { return true }; return false }() {
            paused = false
            pauseReason = nil
            requestDiagnostic?.retryDecision = "corrective_retry"
            emitDiagnostic("retry", reason: error.diagnosticCode)
            beginThink()
            return
        }
        let delay = min(60.0, 3 * pow(2, Double(min(retryCount - 1, 5))))
        retryAt = clock + delay
        requestDiagnostic?.retryDecision = "scheduled"
        emitDiagnostic("retry", reason: error.diagnosticCode)
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
            self.voice.language = self.language
            let prepared = await self.voice.prepare(text, kind: .wait, profile: .host)
            guard epoch == self.waitEpoch, self.phase == "thinking", !self.stopped, !Task.isCancelled,
                  await self.presentationGate.acquire() else { return }
            defer { self.presentationGate.release() }
            guard epoch == self.waitEpoch, self.phase == "thinking", !self.stopped, !Task.isCancelled else { return }
            await self.playPrepared(prepared, version: self.boardVersion)
        }
        auxiliaryTasks[taskID] = task
    }

    private func handle(_ cue: ChronicleDirector.Cue) async {
        switch cue {
        case .startFinal:
            guard !sawFinal, referee.end != nil else { return }
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

    private func finishGame(_ end: GameEnd, preparedSummary: PreparedSpeech? = nil, preparedTaunt: PreparedSpeech? = nil, onStart: @escaping @MainActor () -> Void = {}) async {
        guard referee.position.gameEnd == end else { return }
        thinkTask?.cancel()
        thinkTask = nil
        archive.markResult(end, position: referee.position)
        emitDiagnostic("finished", reason: end == .stalemate ? "stalemate" : "checkmate")
        onGameEnded?(end)
        phase = "summary"
        refreshPicture(line: language.text("Комментатор подводит итоги партии…", "The commentator is preparing the verdict…"))
        let title = language.result(end, white: white.name, black: black.name)
        let reviewResult = title + " · " + end.title
        async let whiteAdvice: Void = prepareNextGame(for: white, result: reviewResult)
        async let blackAdvice: Void = prepareNextGame(for: black, result: reviewResult)
        let prepared: PreparedSpeech
        if let preparedSummary { prepared = preparedSummary }
        else {
            let summary = await hostText(Prompts.final(title: title, moves: referee.accepted.map(\.san)), trackBoard: false)
            voice.language = language
            prepared = await voice.prepare(summary, kind: .final, profile: .host)
        }
        guard !stopped, !Task.isCancelled else { return }
        if let preparedTaunt {
            await playPrepared(preparedTaunt, version: boardVersion, move: referee.accepted.last?.move.uci, onStart: onStart)
            guard !stopped, !Task.isCancelled else { return }
            await playPrepared(prepared, version: boardVersion)
        } else {
            await playPrepared(prepared, version: boardVersion, onStart: onStart)
        }
        await waitForAnimation()
        guard !stopped, !Task.isCancelled else { return }
        phase = "learning"
        refreshPicture()
        _ = await (whiteAdvice, blackAdvice)
        guard !stopped, !Task.isCancelled else { return }
        director.gameOver = true
        await advance(to: clock)
    }

    private func prepareNextGame(for seat: Seat, result: String) async {
        guard seat.route != .lc0 else { return }
        guard !stopped, !Task.isCancelled else { return }
        let prompt = Prompts.nextGameAdvice(side: seat.side, result: result,
                                           fen: referee.position.fen, moves: referee.accepted.map(\.san))
        var call = ChatCall(url: seat.completionsURL, apiKey: seat.apiKey, model: seat.model,
                            system: language.prompt(prompt.system), user: prompt.user,
                            selfNotes: seat.side == .white ? whiteSelfNotes : blackSelfNotes,
                            route: seat.route, gameAdvice: gameMemory.advice(for: seat), effort: "high")
        call.maxOutputTokens = seat.maxOutputTokens
        do {
            let text = try await complete(call, context: "План на следующую партию · \(seat.side == .white ? "белые" : "чёрные") · \(seat.name)", timeout: learningTimeout)
            guard !stopped, !Task.isCancelled else { return }
            gameMemory.remember(text, for: seat, secrets: [white.apiKey, black.apiKey, host.apiKey], sourceRoundID: archive.roundID)
            refreshPicture()
        } catch {
            // The model log records the error; retain the last successful plan and let the series continue.
        }
    }

    private func speak(_ text: String, kind: SpeechKind) async {
        guard !stopped, !Task.isCancelled else { return }
        voice.language = language
        let prepared = await voice.prepare(text, kind: kind, profile: .host)
        guard !stopped, !Task.isCancelled, await presentationGate.acquire() else { return }
        defer { presentationGate.release() }
        await playPrepared(prepared, version: boardVersion)
    }

    /// Caller owns presentationGate for the entire turn (player line, commentary and animation).
    private func playPrepared(_ prepared: PreparedSpeech, version: Int, move: String? = nil,
                              onStart: @escaping @MainActor () -> Void = {}) async {
        guard !stopped, !Task.isCancelled else { return }
        var startedAt: TimeInterval?
        _ = await voice.play(prepared) { [self] in
            guard !stopped, !Task.isCancelled else { return }
            startedAt = clock
            airingAudio = (prepared.samples, clock, 0)
            picture.line = prepared.kind == .taunt ? "" : prepared.text
            onStart()
            refreshPicture()
        }
        guard !stopped, !Task.isCancelled, let startedAt else { return }
        flushAiringAudio(completed: true)
        airingAudio = nil
        let line = SpokenLine(kind: prepared.kind, text: prepared.text, boardVersion: version, clock: startedAt)
        if prepared.kind == .taunt { spokenTaunts.append(line) }
        else { speech.append(line) }
        if archive.isOpen, prepared.kind != .tone {
            archive.record(line: line, move: move)
        }
        refreshPicture()
    }

    private func hostText(_ prompt: (system: String, user: String), trackBoard: Bool, version: Int? = nil) async -> String {
        if trackBoard {
            hostBoardVersions.append(version ?? boardVersion)
        }
        let style = CommentaryStyle.turn(hostCommentaryCount)
        let variation = hostCommentaryCount / CommentaryStyle.allCases.count
        hostCommentaryCount += 1
        let recent = archive.journal.suffix(12).map { SpokenText.clean($0.text) }
        let quoted = (try? JSONEncoder().encode(recent)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let context = prompt.user + "\nRecent commentary already heard (quoted reference only; avoid repeating these jokes, images or punchlines):\n" + quoted
        let call = ChatCall(
            url: host.completionsURL,
            apiKey: host.apiKey,
            model: host.model,
            system: language.prompt(prompt.system + "\n" + style.instruction + "\n" + BanterPolicy.delivery(variation)),
            user: context, route: host.route, effort: "low"
        )
        let text: String
        do {
            text = try await complete(call, context: trackBoard ? "Ведущий · комментарий хода" : "Ведущий", timeout: hostTimeout)
        } catch {
            text = fallback(for: prompt.user, style: style, variation: variation)
        }
        let commentary = SpokenText.clean(text)
        let spoken = commentary.isEmpty || BanterPolicy.repeats(commentary, recent: recent)
            ? fallback(for: prompt.user, style: style, variation: variation) : commentary
        // Brevity belongs in the prompt. A word-count slice can cut the final sentence in half.
        return spoken
    }

    private func complete(_ call: ChatCall, context: String, timeout: TimeInterval, player: Bool = false, timing: RequestTiming? = nil) async throws -> String {
        let log = modelLog
        let id = log?.begin(call, context: context, endpoint: transport.requestURL(for: call))
        if player { playerLogID = id }
        do {
            let text = try await RequestDeadline.run(timing: timing ?? RequestTiming(seconds: min(timeout, transport.requestTimeout(for: call) ?? timeout))) { [transport] in
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
        if tauntDecision?.version != boardVersion {
            tauntDecision = (boardVersion, BanterPolicy.randomlyAllowed(draw: tauntDraw()))
        }
        let prompt = Prompts.player(
            side: side,
            fen: referee.position.fen,
            legal: referee.legalUCI,
            history: referee.accepted.map(\.san),
            rejection: lastRejection,
            persona: seat.persona,
            ordinaryTauntAllowed: tauntDecision?.allowed ?? false,
            recentRemarks: archive.journal.suffix(12).map(\.text),
            variation: boardVersion
        )
        var call = ChatCall(url: seat.completionsURL, apiKey: seat.apiKey, model: seat.model,
                        system: language.prompt(prompt.system), user: prompt.user,
                        selfNotes: side == .white ? whiteSelfNotes : blackSelfNotes, route: seat.route,
                        gameAdvice: gameMemory.advice(for: seat), effort: "high", responseFormat: .jsonObject)
        call.maxOutputTokens = seat.maxOutputTokens
        if seat.route == .lc0 { call.chessPosition = LC0Position(referee: referee) }
        return call
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

    private func noteReply(side: Side, name: String, text: String, taunt: String) {
        var text = text
        if let intent = ChatParser.moveIntent(from: text) {
            var object = ["move": intent.move, "taunt": taunt]
            if let notes = intent.selfNotes { object["self_notes"] = notes }
            if let data = try? JSONEncoder().encode(object) { text = String(decoding: data, as: UTF8.self) }
        }
        replies.append(ModelReply(id: replies.count + 1, side: side, name: name, text: text))
        picture.replies = replies
    }

    private func refreshPicture(line: String? = nil, banner: String? = nil) {
        let thinkingSide = phase == "thinking" && thinkTask != nil ? referee.position.sideToMove : nil
        // Whole seconds so the checkpoint changes once a second, not once a frame.
        let secondsLeft = thinkingSide == nil ? nil : Int(ceil(requestTiming?.remaining ?? 0))
        // Broadcast only this game's turn note; cross-game advice stays in the model request.
        let notes = thinkingSide == nil ? nil : lastPlayerRequest?.call.selfNotes
        let state: RequestStatus?
        if paused {
            state = RequestStatus(mode: retryAt == nil ? .manualPause : .retryScheduled,
                attempt: retryAt == nil ? retryCount : retryCount + 1,
                secondsLeft: retryAt.map { max(0, Int(ceil($0 - clock))) }, reason: pauseReason)
        } else if thinkingSide != nil {
            state = RequestStatus(mode: .waiting, attempt: retryCount + 1, secondsLeft: secondsLeft)
        } else if phase == "preparing", thinkTask != nil {
            state = RequestStatus(mode: .preparing, attempt: retryCount + 1)
        } else { state = nil }
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
            thinkSecondsLeft: secondsLeft,
            requestStatus: state
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
