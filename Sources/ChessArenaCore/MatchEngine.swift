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

    public private(set) var referee = Referee()
    public private(set) var director = ChronicleDirector()
    public private(set) var speech: [SpokenLine] = []
    public private(set) var picture: BroadcastPicture
    public private(set) var phase = "idle"
    public private(set) var clock: TimeInterval = 0
    public private(set) var moveRequestCount = 0
    public private(set) var boardVersion = 0
    public private(set) var chronicleVisuals = 0
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
    private var chronicleText: String?
    private var chronicleVoiceSent = false
    private var deferredMove: (String, Int)?
    private var animatingUntil: TimeInterval?
    private var speaking = false
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
        let line = SpokenLine(kind: .tone, text: ModelCatalog.toneTest, boardVersion: boardVersion, clock: clock)
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
        clock = time
        if let until = animatingUntil, time >= until {
            animatingUntil = nil
            scene.finishAnimation()
        }
        syncBlocked()
        let cues = director.advance(to: time, voiceText: chronicleText)
        for cue in cues {
            await handle(cue)
        }
        maybeWaitLine()
        refreshPicture()
    }

    public func resume() {
        guard paused, referee.end == nil else { return }
        paused = false
        pauseReason = nil
        phase = "thinking"
        beginThink()
    }

    public func appendFrame(_ buffer: CVPixelBuffer) {
        guard archive.isOpen else { return }
        archive.append(pixelBuffer: buffer)
    }

    public func closeArchive() async throws {
        try await archive.finish(end: referee.end)
    }

    private func beginThink() {
        guard thinkTask == nil, referee.end == nil, !paused, !chronicleActive, !finalActive else { return }
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
            do {
                let text = try await self.transport.complete(call)
                self.onPlayerWaiting?()
                await self.ingest(text, generation: generation)
            } catch let error as ChatError where error == .unreadable {
                self.onPlayerWaiting?()
                await self.ingest("", generation: generation)
            } catch {
                self.onPlayerWaiting?()
                await self.stall(generation: generation, error: error as? ChatError ?? .transport)
            }
        }
        refreshPicture()
    }

    private func ingest(_ text: String, generation: Int, record: Bool = true) async {
        guard generation == thinkGeneration else { return }
        thinkTask = nil
        waitEpoch += 1
        scene.setThinking(nil)
        picture.thinkingSide = nil
        if record {
            let side = referee.position.sideToMove
            let seat = side == .white ? white : black
            noteReply(side: side, name: seat.name, text: text)
        }
        if chronicleActive || finalActive {
            deferredMove = (text, generation)
            return
        }
        let intent = ChatParser.moveIntent(from: text)
        let submission = referee.submit(rawMove: intent?.move ?? text, taunt: intent?.taunt ?? "")
        switch submission {
        case .accepted(let move, let end):
            lastRejection = nil
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
                syncBlocked()
            }
            picture.taunt = move.taunt
            archive.record(move: move, clock: clock)
            refreshPicture()
            let commentary = await hostText(Prompts.moveCommentary(fen: referee.position.fen, san: move.san), trackBoard: true)
            await speak(commentary, kind: .move)
            if let end {
                await finishGame(end)
            } else {
                beginThink()
            }
        case .rejected(let reason, _):
            lastRejection = reason
            beginThink()
        case .resigned(let end):
            let loser = end.winner?.opposite ?? referee.position.sideToMove
            await speak(await hostText(Prompts.resignation(side: loser), trackBoard: false), kind: .resignation)
            await finishGame(end)
        case .ignored:
            break
        }
    }

    private func stall(generation: Int, error: ChatError) async {
        guard generation == thinkGeneration else { return }
        thinkTask = nil
        waitEpoch += 1
        paused = true
        phase = "paused"
        scene.setThinking(nil)
        let side = referee.position.sideToMove
        let seat = side == .white ? white : black
        pauseReason = "\(seat.name): \(error.userMessage)"
        refreshPicture()
        await speak(await hostText(Prompts.stall(side: side), trackBoard: false), kind: .stall)
        refreshPicture(line: picture.line)
    }

    private func maybeWaitLine() {
        guard phase == "thinking", !waitSpoken, clock - thinkStarted >= 20, thinkTask != nil else { return }
        waitSpoken = true
        let epoch = waitEpoch
        let side = referee.position.sideToMove
        Task { [weak self] in
            guard let self else { return }
            let text = await self.hostText(Prompts.waiting(side: side), trackBoard: false)
            guard epoch == self.waitEpoch, self.phase == "thinking" else { return }
            await self.speak(text, kind: .wait)
        }
    }

    private func handle(_ cue: ChronicleDirector.Cue) async {
        switch cue {
        case .prepare:
            let previous = speech.filter { $0.kind == .chronicle }.map(\.text)
            let moves = referee.accepted.map(\.san)
            Task { [weak self] in
                guard let self else { return }
                let text = await self.hostText(Prompts.chronicle(moves: moves, previous: previous), trackBoard: false)
                self.chronicleText = text
                if self.chronicleActive, !self.chronicleVoiceSent {
                    self.chronicleVoiceSent = true
                    await self.speak(text, kind: .chronicle)
                }
            }
        case .startChronicle:
            phase = "chronicle"
            chronicleVisuals += 1
            chronicleVoiceSent = false
            let moves = referee.accepted.map(\.move)
            let sides = moves.indices.map { $0.isMultiple(of: 2) ? Side.white : Side.black }
            scene.layChronicle(moves: moves, sides: sides)
            refreshPicture(banner: "THE STORY SO FAR")
            if let chronicleText {
                chronicleVoiceSent = true
                await speak(chronicleText, kind: .chronicle)
            }
        case .startVoice(let text):
            guard !chronicleVoiceSent else { return }
            chronicleVoiceSent = true
            await speak(text, kind: .chronicle)
        case .endChronicle:
            picture.banner = nil
            if let deferred = deferredMove {
                deferredMove = nil
                await ingest(deferred.0, generation: deferred.1, record: false)
            } else if referee.end == nil, !paused, thinkTask == nil {
                phase = "thinking"
                beginThink()
            }
            refreshPicture()
        case .startFinal:
            guard !sawFinal else { return }
            sawFinal = true
            finalCards += 1
            phase = "final"
            let moves = referee.accepted.map(\.move)
            let sides = moves.indices.map { $0.isMultiple(of: 2) ? Side.white : Side.black }
            scene.layChronicle(moves: moves, sides: sides)
            let title = referee.end?.title ?? "GAME OVER"
            refreshPicture(banner: title)
            let line = await hostText(Prompts.final(title: title, moves: referee.accepted.map(\.san)), trackBoard: false)
            await speak(line, kind: .final)
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
        phase = "finished"
        await advance(to: clock)
    }

    private func speak(_ text: String, kind: SpeechKind) async {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        speaking = true
        syncBlocked()
        phase = kind == .move || kind == .wait ? phase : phase
        let samples = await voice.speak(spoken, kind: kind)
        speaking = false
        syncBlocked()
        let line = SpokenLine(kind: kind, text: spoken, boardVersion: boardVersion, clock: clock)
        speech.append(line)
        if archive.isOpen, kind != .tone {
            archive.record(line: line)
            archive.appendAudio(samples)
        }
        picture.line = spoken
        refreshPicture()
        if kind != .chronicle && kind != .final {
            syncBlocked()
            let cues = director.advance(to: clock, voiceText: chronicleText)
            for cue in cues {
                await handle(cue)
            }
        }
    }

    private func hostText(_ prompt: (system: String, user: String), trackBoard: Bool) async -> String {
        if trackBoard {
            hostBoardVersions.append(boardVersion)
        }
        let call = ChatCall(
            url: host.completionsURL,
            apiKey: host.apiKey,
            model: host.model,
            system: prompt.system,
            user: prompt.user
        )
        let text: String
        do {
            text = try await transport.complete(call)
        } catch {
            text = fallback(for: prompt.user)
        }
        if prompt.system.contains("from move one") || prompt.system.contains("at most 35") {
            return limitWords(text)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return ChatCall(url: seat.completionsURL, apiKey: seat.apiKey, model: seat.model, system: prompt.system, user: prompt.user)
    }

    private func fallback(for user: String) -> String {
        if user.contains("resigns") { return "That side resigns. The board accepts." }
        if user.contains("stalled") { return "That player has stalled. The match is paused." }
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

    private func syncBlocked() {
        director.blocked = speaking || animatingUntil != nil || scene.isAnimating
    }

    private var chronicleActive: Bool {
        if case .chronicle = director.phase { return true }
        return false
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
