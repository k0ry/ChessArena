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
    public var hostTimeout: TimeInterval = 12
    public var onGameEnded: ((GameEnd) -> Void)?
    public private(set) var retryAt: TimeInterval?
    private var retryCount = 0
    private var stopped = false
    private var auxiliaryTasks: [UUID: Task<Void, Never>] = [:]
    private var turnTasks: [Int: Task<Void, Never>] = [:]

    public private(set) var referee = Referee()
    public private(set) var director = ChronicleDirector()
    public private(set) var speech: [SpokenLine] = []
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
    private var thinkGeneration = 0
    private var waitEpoch = 0
    private var thinkStarted: TimeInterval = 0
    private var waitSpoken = false
    private var lastRejection: String?
    private var animatingUntil: TimeInterval?
    private var started = false
    private var sawFinal = false
    private var replies: [ModelReply] = []

    public init(scene: BoardScene, voice: Voice, transport: ChatTransport, archive: MatchArchive, white: Seat, black: Seat, host: Seat) {
        self.scene = scene
        self.voice = voice
        self.transport = transport
        self.archive = archive
        self.white = white
        self.black = black
        self.host = host
        picture = BroadcastPicture(
            whiteName: white.name,
            blackName: black.name,
            clockText: "00:00",
            line: "",
            taunt: "",
            banner: nil
        )
    }

    public func toneTest() async -> SpokenLine {
        voice.language = language
        let line = SpokenLine(kind: .tone, text: language.toneTest, boardVersion: boardVersion, clock: clock)
        _ = await voice.speak(line.text, kind: .tone)
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
        refreshPicture()
        beginThink()
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

    private func beginThink() {
        guard !stopped, thinkTask == nil, referee.end == nil, !paused, !finalActive else { return }
        thinkGeneration += 1
        let generation = thinkGeneration
        thinkStarted = clock
        waitSpoken = false
        phase = "thinking"
        scene.setThinking(referee.position.sideToMove)
        let call = playerCall()
        moveRequestCount += 1
        thinkTask = Task { [weak self] in
            guard let self else { return }
            defer { self.turnTasks.removeValue(forKey: generation) }
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
        let side = referee.position.sideToMove
        let seat = side == .white ? white : black
        noteReply(side: side, name: seat.name, text: text)
        let intent = ChatParser.moveIntent(from: text)
        let submission = referee.submit(rawMove: intent?.move ?? text, taunt: intent?.taunt ?? "")
        switch submission {
        case .accepted(let move, let end):
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
            archive.record(move: move, clock: clock)
            refreshPicture()
            if let end {
                await finishGame(end)
            } else {
                let commentary = await hostText(Prompts.moveCommentary(fen: referee.position.fen, san: move.san), trackBoard: true)
                guard !stopped else { return }
                await speak(commentary, kind: .move)
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
            let taskID = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                defer { self.auxiliaryTasks.removeValue(forKey: taskID) }
                let line = await self.hostText(Prompts.final(title: title, moves: self.referee.accepted.map(\.san)), trackBoard: false)
                await self.speak(line, kind: .final)
            }
            auxiliaryTasks[taskID] = task
        case .endFinal:
            phase = "finished"
            refreshPicture()
        }
    }

    private func finishGame(_ end: GameEnd) async {
        thinkTask?.cancel()
        thinkTask = nil
        director.gameOver = true
        archive.markResult(end)
        onGameEnded?(end)
        phase = "final"
        await advance(to: clock)
    }

    private func speak(_ text: String, kind: SpeechKind) async {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stopped, !Task.isCancelled, !spoken.isEmpty else { return }
        voice.language = language
        let samples = (try? await RequestDeadline.run(seconds: 20) { [voice] in
            await voice.speak(spoken, kind: kind)
        }) ?? []
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

    private func hostText(_ prompt: (system: String, user: String), trackBoard: Bool) async -> String {
        if trackBoard {
            hostBoardVersions.append(boardVersion)
        }
        let call = ChatCall(
            url: host.completionsURL,
            apiKey: host.apiKey,
            model: host.model,
            system: language.prompt(prompt.system),
            user: prompt.user
        )
        let text: String
        do {
            text = try await complete(call, context: trackBoard ? "Ведущий · комментарий хода" : "Ведущий", timeout: hostTimeout)
        } catch {
            text = fallback(for: prompt.user)
        }
        if prompt.system.contains("from move one") || prompt.system.contains("at most 35") {
            return limitWords(text)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            rejection: lastRejection
        )
        return ChatCall(url: seat.completionsURL, apiKey: seat.apiKey, model: seat.model, system: language.prompt(prompt.system), user: prompt.user)
    }

    private func fallback(for user: String) -> String {
        if language == .russian {
            if user.contains("resigns") { return "Игрок сдаётся. Партия завершена." }
            if user.contains("stalled") { return "Повторяем запрос. Партия продолжится автоматически." }
            if user.contains("still thinking") { return "Игрок обдумывает следующий ход." }
            if user.contains("Result:") { return referee.end.map { language.result($0, white: white.name, black: black.name) } ?? "Партия завершена." }
            return "Ход сделан. Игра продолжается."
        }
        if user.contains("resigns") { return "That side resigns. The board accepts." }
        if user.contains("stalled") { return "Retrying the request. The match will continue automatically." }
        if user.contains("still thinking") { return "Still thinking. The clock keeps its own counsel." }
        if user.contains("Result:") { return "The game is over, and the pieces look relieved." }
        return "The position has changed, and it has opinions about it."
    }

    private func noteReply(side: Side, name: String, text: String) {
        replies.append(ModelReply(id: replies.count + 1, side: side, name: name, text: text))
        picture.replies = replies
    }

    private func refreshPicture(line: String? = nil, banner: String? = nil) {
        picture = BroadcastPicture(
            whiteName: white.name,
            blackName: black.name,
            clockText: ClockFormat.string(clock),
            line: line ?? picture.line,
            taunt: picture.taunt,
            banner: banner ?? picture.banner,
            replies: replies,
            thinkingSide: phase == "thinking" && thinkTask != nil ? referee.position.sideToMove : nil,
            pausedPlayer: paused ? (referee.position.sideToMove == .white ? white.name : black.name) : nil
        )
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
