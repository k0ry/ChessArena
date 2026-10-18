import Foundation

public enum LocalQwenConfiguration {
    public static let model = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit"
    public static let voices = ["Ryan", "Aiden", "Uncle_Fu", "Dylan", "Eric", "Vivian", "Serena", "Ono_Anna", "Sohee"]
    public static let endpoint = URL(string: "http://127.0.0.1:8769/v1/audio/speech")!
}

struct QwenSpeechAPI {
    var network: URLSession = .shared
    var endpoint = LocalQwenConfiguration.endpoint

    func audio(text: String, voice: String, language: BroadcastLanguage, instructions: String) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Local speech never receives an OpenAI key or the ChatGPT session.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": LocalQwenConfiguration.model, "input": text, "voice": voice,
            "language": language == .russian ? "Russian" : "English",
            "instructions": instructions, "response_format": "pcm"
        ])
        return try await NetworkTrace.track(.localSpeech, request: request) { trace in
            let (data, response) = try await network.data(for: request)
            await trace.response(response, bytes: data.count)
            guard let http = response as? HTTPURLResponse else {
                throw SpeechFailure(message: "Локальный Qwen не вернул HTTP-ответ.")
            }
            guard http.statusCode == 200 else {
                throw SpeechFailure(message: "Локальный Qwen: HTTP \(http.statusCode). " +
                    (http.statusCode == 503 ? "Генератор занят, попробуйте ещё раз." : "Не удалось синтезировать речь."))
            }
            guard !data.isEmpty, data.count % 2 == 0, data.count <= 10_000_000,
                  !(http.mimeType ?? "").contains("json") else {
                throw SpeechFailure(message: "Локальный Qwen вернул некорректный PCM-звук.")
            }
            return data
        }
    }
}

/// Starts the installed MLX environment on demand; only terminates its own child process.
@MainActor
final class LocalQwenServer {
    private var process: Process?
    private var startup: Task<Void, Error>?
    private let directory: URL
    private let script: URL
    private let network: URLSession

    init(directory: URL? = nil, script: URL? = nil) {
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        self.directory = directory ?? root.appendingPathComponent(".local-tts")
        self.script = script ?? (Bundle.main.resourceURL ?? root).appendingPathComponent("qwen-server.py")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 2
        network = URLSession(configuration: config)
    }

    func ensureRunning() async throws {
        try Task.checkCancellation()
        if let startup { try await startup.value; return }
        let task = Task { @MainActor in
            if await self.isReady() { return }
            try Task.checkCancellation()
            let python = self.directory.appendingPathComponent("venv/bin/python")
            let model = self.directory.appendingPathComponent("model")
            guard FileManager.default.isExecutableFile(atPath: python.path),
                  FileManager.default.fileExists(atPath: model.appendingPathComponent("config.json").path),
                  FileManager.default.fileExists(atPath: self.script.path) else {
                throw SpeechFailure(message: "Qwen не установлен рядом с ChessArena.app. Выполните scripts/setup-local-tts.sh в папке проекта.")
            }
            if self.process?.isRunning != true {
                let process = Process()
                process.executableURL = python
                process.arguments = [self.script.path, "--model", model.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
                var environment = ProcessInfo.processInfo.environment
                environment["HF_HOME"] = self.directory.appendingPathComponent("cache").path
                environment["HF_HUB_OFFLINE"] = "1"
                environment["TOKENIZERS_PARALLELISM"] = "false"
                process.environment = environment
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    throw SpeechFailure(message: "Не удалось запустить локальный Python для Qwen.")
                }
                self.process = process
            }
            for _ in 0..<90 {
                try Task.checkCancellation()
                if await self.isReady() { return }
                guard self.process?.isRunning == true else {
                    throw SpeechFailure(message: "Локальный Qwen завершился при запуске. Проверьте установку scripts/setup-local-tts.sh.")
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            self.stop()
            throw SpeechFailure(message: "Локальный Qwen не успел загрузить модель.")
        }
        startup = task
        defer { startup = nil }
        try await task.value
    }

    private func isReady() async -> Bool {
        let url = URL(string: "http://127.0.0.1:8769/health")!
        guard let (data, response) = try? await network.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["service"] as? String == "chessarena-qwen-tts-v1" &&
            object["model"] as? String == LocalQwenConfiguration.model
    }

    func stop() {
        startup?.cancel()
        startup = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }
}
