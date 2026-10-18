import AVFoundation
import Combine
import Foundation

public enum VoiceProviderChoice: String, Codable, CaseIterable {
    case system, openAIKey, localQwen
}

/// Only bounded identifiers and known error codes may leave the HTTP boundary.
public struct SpeechFailure: Error {
    public let message: String
    static func http(_ response: HTTPURLResponse, data: Data, subscription: Bool, secret: String) -> SpeechFailure {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = body?["error"] as? [String: Any]
        let known = Set(["invalid_api_key", "insufficient_quota", "rate_limit_exceeded", "model_not_found", "permission_denied", "invalid_request_error", "authentication_error", "subscription_sharing_invalid_user", "subscription_sharing_route_not_supported", "subscription_sharing_unsupported_capability"])
        let code = error?["code"] as? String ?? error?["type"] as? String ?? ""
        let reason: String
        switch response.statusCode {
        case 401: reason = subscription ? "Токен входа ChatGPT не принят сервисом озвучки. Доступ к текстовым моделям не подтверждает доступ к аудио." : "Сервис озвучки отклонил API-ключ. Проверьте отдельный ключ для речи."
        case 403: reason = "Нет разрешения на озвучку или доступ из текущего региона."
        case 429: reason = code == "insufficient_quota" ? "Недостаточно API-кредитов для озвучки." : "Превышен лимит запросов озвучки."
        case 404: reason = "Модель озвучки недоступна."
        case 500...599: reason = "Сервис озвучки временно недоступен."
        default: reason = "Сервис отклонил параметры запроса озвучки."
        }
        var message = "HTTP \(response.statusCode): \(reason)"
        if known.contains(code), !code.contains(secret), !secret.isEmpty { message += " Код: \(code)." }
        if let id = response.value(forHTTPHeaderField: "x-request-id"),
           id.range(of: "^(req_[A-Za-z0-9_-]{8,100}|[a-fA-F0-9-]{32,36})$", options: .regularExpression) != nil,
           !secret.isEmpty, !id.contains(secret) { message += " Request ID: \(id)." }
        return SpeechFailure(message: message)
    }
    static func describe(_ error: Error) -> String {
        if let error = error as? SpeechFailure { return error.message }
        if let error = error as? URLError { return "Ошибка сети озвучки: NSURLErrorDomain \(error.code.rawValue)." }
        return "Не удалось воспроизвести ответ сервиса озвучки."
    }
}

struct SpeechAPI {
    var network: URLSession = .shared
    var endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
    func audio(text: String, voice: String, instructions: String, key: String) async throws -> Data {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SpeechFailure(message: "Введите отдельный API-ключ OpenAI для озвучки.") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 12
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "gpt-4o-mini-tts", "voice": voice, "input": text, "instructions": instructions, "response_format": "pcm"])
        return try await NetworkTrace.track(.speechAPI, request: request) { trace in
            let (data, response) = try await network.data(for: request)
            await trace.response(response, bytes: data.count)
            guard let http = response as? HTTPURLResponse else { throw SpeechFailure(message: "Нет HTTP-ответа озвучки.") }
            guard (200..<300).contains(http.statusCode) else { throw SpeechFailure.http(http, data: data, subscription: false, secret: key) }
            guard !data.isEmpty, data.count % 2 == 0, data.count <= 10_000_000,
                  !(http.mimeType ?? "").contains("json") else { throw SpeechFailure(message: "Некорректный PCM-ответ озвучки.") }
            return data
        }
    }
}

@MainActor
public final class BroadcastVoice: ObservableObject, Voice {
    public var language: BroadcastLanguage = .russian
    public var provider: VoiceProviderChoice = .system {
        didSet {
            if provider != .localQwen { localServer?.stop() }
            switch provider {
            case .system: status = "Системная озвучка"
            case .openAIKey: status = "OpenAI · готов к проверке тона"
            case .localQwen: status = "Qwen · готов к проверке тона"
            }
        }
    }
    public var apiKey = ""
    public var hostVoice = "onyx"
    public var qwenVoice = "Ryan"
    public var qwenCasting = QwenVoiceCasting()
    public static let voices = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse", "marin", "cedar"]
    @Published public private(set) var status = "Системная озвучка"
    public private(set) var isSpeaking = false
    private let fallback: Voice
    private let api: SpeechAPI
    private let localAPI: QwenSpeechAPI
    private let localServer: LocalQwenServer?
    private let player = PreparedAudioPlayer()
    private let synthesisGate = SpeechGate()
    private let playbackGate = SpeechGate()
    private var generation = UUID()
    private var pending: Task<Data, Error>?
    public convenience init() { self.init(fallback: SystemVoice(), api: SpeechAPI(), localServer: LocalQwenServer()) }
    init(fallback: Voice, api: SpeechAPI, localAPI: QwenSpeechAPI = QwenSpeechAPI(), localServer: LocalQwenServer? = nil) {
        self.fallback = fallback; self.api = api; self.localAPI = localAPI; self.localServer = localServer
    }
    public func shutdown() { stop(); localServer?.stop() }
    public func stop() {
        generation = UUID(); pending?.cancel(); pending = nil
        synthesisGate.cancelPending(); playbackGate.cancelPending()
        player.stop(); fallback.stop(); isSpeaking = false
    }

    public func prepare(_ text: String, kind: SpeechKind, profile: VoiceProfile) async -> PreparedSpeech {
        let epoch = generation
        let text = SpokenText.clean(text)
        var speech = PreparedSpeech(text: text, kind: kind, profile: profile, samples: [])
        guard !text.isEmpty, await synthesisGate.acquire() else { return speech }
        defer { synthesisGate.release() }
        guard epoch == generation, !Task.isCancelled else { return speech }
        fallback.language = language
        if provider == .system {
            speech = await fallback.prepare(text, kind: kind, profile: profile)
            speech.usesFallback = true; speech.status = "Системная озвучка"
            return speech
        }
        let local = provider == .localQwen
        if !isSpeaking { status = local ? "Qwen · загрузка / генерация речи…" : "OpenAI · получение озвучки…" }
        let selected: String
        switch profile {
        case .host: selected = local ? qwenVoice : hostVoice
        case .persona(let persona):
            selected = local ? qwenCasting.voice(for: persona)
                : Self.voices[PlayerPersona.allCases.firstIndex(of: persona)! % Self.voices.count]
        }
        let delivery = profile.neuralDelivery
        let speechLanguage = language
        let key = apiKey
        let task = Task {
            if local {
                try await localServer?.ensureRunning()
                try Task.checkCancellation()
                return try await localAPI.audio(text: text, voice: selected, language: speechLanguage, instructions: delivery)
            }
            return try await api.audio(text: text, voice: selected, instructions: "Speak in \(speechLanguage.rawValue). \(delivery)", key: key)
        }
        pending = task
        defer { if epoch == generation { pending = nil } }
        do {
            let pcm = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard epoch == generation, !Task.isCancelled else { return speech }
            speech.samples = Self.archiveSamples(pcm)
            speech.status = "\(local ? "Qwen · локально" : "OpenAI") · \(selected)"
        } catch {
            guard epoch == generation, !Task.isCancelled, !(error is CancellationError) else { return speech }
            speech = await fallback.prepare(text, kind: kind, profile: profile)
            speech.usesFallback = true
            speech.status = SpeechFailure.describe(error) + " Используется системный голос."
        }
        return speech
    }

    public func play(_ speech: PreparedSpeech, onStart: @escaping @MainActor () -> Void) async -> [Int16] {
        let epoch = generation
        guard await playbackGate.acquire() else { return [] }
        defer { playbackGate.release() }
        guard epoch == generation, !Task.isCancelled else { return [] }
        isSpeaking = true
        defer { if epoch == generation { isSpeaking = false } }
        if let message = speech.status { status = message }
        if speech.usesFallback { return await fallback.play(speech, onStart: onStart) }
        return await player.play(speech.samples, onStart: onStart)
    }
    static func wav(_ pcm: Data, sampleRate: UInt32 = 24_000) -> Data {
        var data = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ n: T) { var value = n.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        number(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8))
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(sampleRate); number(sampleRate * 2); number(UInt16(2)); number(UInt16(16))
        data.append(Data("data".utf8)); number(UInt32(pcm.count)); data.append(pcm); return data
    }
    /// PCM from Speech API is mono 24 kHz; archive contract is mono 44.1 kHz.
    static func archiveSamples(_ pcm: Data) -> [Int16] {
        let bytes = [UInt8](pcm)
        let samples = stride(from: 0, to: bytes.count - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0+1]) << 8) }
        return AudioSamples.resample(samples, from: 24_000)
    }
}
