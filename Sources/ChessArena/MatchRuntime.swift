import ChessArenaCore
import Foundation

@MainActor
final class MatchRuntime: ObservableObject {
    @Published var picture = BroadcastPicture.empty
    let chatGPT = ChatGPTConnection()
    @Published var useChatGPTLogin = true
    @Published var grokKey = ""
    @Published var chatKey = ""
    @Published var whiteModel = ModelCatalog.grokModel
    @Published var blackModel = ModelCatalog.chatGPTModel
    @Published var status = "Готово к эфиру"
    @Published var moveNumber = 1
    @Published var paused = false
    @Published var matchRunning = false

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
    }

    func tone() {
        guard engine == nil else { return }
        Task {
            _ = await voice.speak(ModelCatalog.toneTest, kind: .tone)
        }
    }

    func startMatch() {
        guard engine == nil else { return }
        guard !grokKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Введите ключ Grok для белых и ведущего"; return
        }
        if useChatGPTLogin {
            guard chatGPT.connected, let selected = chatGPT.models.first(where: { $0.id == blackModel }) ?? chatGPT.models.first else {
                status = "Сначала нажмите Continue with ChatGPT"; return
            }
            blackModel = selected.id
        } else if chatKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = "Введите ключ OpenAI или войдите через ChatGPT"; return
        }
        scene.show(position: .standard())
        try? secrets.save(account: "grok", secret: grokKey)
        if !useChatGPTLogin { try? secrets.save(account: "chatgpt", secret: chatKey) }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChessArena", isDirectory: true)
            .appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"), isDirectory: true)
        let archive = MatchArchive(directory: folder, whiteName: "Grok", blackName: "ChatGPT")
        let white = Seat(name: "Grok", baseURL: ModelCatalog.grokAPI, model: whiteModel, apiKey: grokKey, side: .white)
        let black = Seat(name: "ChatGPT", baseURL: ModelCatalog.openAIAPI, model: blackModel, apiKey: chatKey, side: .black)
        let host = Seat(name: "Host", baseURL: ModelCatalog.grokAPI, model: whiteModel, apiKey: grokKey, side: .white)
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
        engine = match
        matchRunning = true
        startedAt = Date()
        status = "Партия идёт"
        Task {
            do {
                try await match.start(at: 0)
                self.picture = match.picture
            } catch {
                self.status = "Архив не открылся. Проверьте доступ к папке Документы."
                self.engine = nil
                self.matchRunning = false
                self.ticker?.cancel()
            }
        }
        ticker = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                await self.tick()
            }
        }
    }

    func resume() {
        guard let engine, engine.paused else { return }
        engine.white.apiKey = grokKey.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.white.model = whiteModel.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.black.apiKey = chatKey.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.black.model = blackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.host.apiKey = engine.white.apiKey
        engine.host.model = engine.white.model
        engine.resume()
        paused = false
        status = "Партия идёт"
    }

    private func tick() async {
        guard let engine, let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        scene.applyCamera(at: elapsed)
        await engine.advance(to: elapsed)
        if let frame = scene.copyFrame() {
            engine.appendFrame(frame)
        }
        picture = engine.picture
        moveNumber = engine.referee.position.fullmove
        paused = engine.paused
        if engine.phase == "finished" {
            status = "Партия завершена"
            try? await engine.closeArchive()
            ticker?.cancel()
            self.engine = nil
            matchRunning = false
        } else if engine.paused {
            status = engine.pauseReason ?? "Пауза: игрок не ответил"
        }
    }
}
