import AVFoundation
import Foundation

public enum SpeechKind: String, Equatable, Sendable {
    case tone
    case move
    case wait
    case resignation
    case stall
    case chronicle
    case final
}

public struct SpokenLine: Equatable, Sendable {
    public var kind: SpeechKind
    public var text: String
    public var boardVersion: Int
    public var clock: TimeInterval
}

@MainActor
public protocol Voice: AnyObject {
    var language: BroadcastLanguage { get set }
    func stop()
    var isSpeaking: Bool { get }
    func speak(_ text: String, kind: SpeechKind) async -> [Int16]
}

@MainActor
public final class ScriptedVoice: Voice {
    public var language: BroadcastLanguage = .english
    public func stop() { release() }
    public private(set) var isSpeaking = false
    public var lines: [SpokenLine] = []
    public var hold = false
    private var waiter: CheckedContinuation<Void, Never>?
    public var onSpeaking: (() -> Void)?

    public init() {}

    public func speak(_ text: String, kind: SpeechKind) async -> [Int16] {
        isSpeaking = true
        onSpeaking?()
        if hold {
            await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }
        isSpeaking = false
        return Array(repeating: 1200, count: 4410)
    }

    public func release() {
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
public final class SystemVoice: NSObject, Voice {
    public var language: BroadcastLanguage = .russian
    public private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineReady = false
    private var utteranceID = UUID()
    private var continuation: CheckedContinuation<[Int16], Never>?
    private var samples: [Int16] = []
    private var pendingBuffers = 0
    private var synthesisFinished = false

    public override init() {
        super.init()
        engine.attach(player)
    }

    public func stop() {
        utteranceID = UUID()
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engineReady = false
        isSpeaking = false
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: [])
    }

    public func speak(_ text: String, kind: SpeechKind) async -> [Int16] {
        stop()
        let id = UUID()
        utteranceID = id
        samples = []; pendingBuffers = 0; synthesisFinished = false
        isSpeaking = true
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { stop(); return [] }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                synthesizer.write(utterance) { [weak self] buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.utteranceID == id else { return }
                        if pcm.frameLength == 0 {
                            self.synthesisFinished = true
                            self.finishIfReady()
                        } else {
                            self.samples.append(contentsOf: Self.int16Samples(from: pcm))
                            self.play(pcm, id: id)
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.utteranceID == id else { return }
                self.stop()
            }
        }
    }

    private func finishIfReady() {
        guard synthesisFinished, pendingBuffers == 0, let continuation else { return }
        self.continuation = nil
        isSpeaking = false
        continuation.resume(returning: samples)
    }

    private func play(_ buffer: AVAudioPCMBuffer, id: UUID) {
        if !engineReady {
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            do { try engine.start() } catch { return }
            player.play()
            engineReady = true
        }
        pendingBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.utteranceID == id else { return }
                self.pendingBuffers -= 1
                self.finishIfReady()
            }
        }
    }

    private static func int16Samples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        if let channel = buffer.int16ChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: frames))
        }
        guard let channel = buffer.floatChannelData else { return [] }
        return UnsafeBufferPointer(start: channel[0], count: frames).map {
            Int16(max(-1, min(1, $0)) * 32767)
        }
    }
}
