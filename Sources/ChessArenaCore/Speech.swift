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

public protocol Voice: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String, kind: SpeechKind) async -> [Int16]
}

public final class ScriptedVoice: Voice {
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

public final class SystemVoice: NSObject, Voice {
    public private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineReady = false

    public override init() {
        super.init()
        engine.attach(player)
    }

    public func speak(_ text: String, kind: SpeechKind) async -> [Int16] {
        isSpeaking = true
        let samples: [Int16] = await withCheckedContinuation { continuation in
            var collected: [Int16] = []
            var resumed = false
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            self.synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: collected)
                    }
                    return
                }
                self.play(pcm)
                collected.append(contentsOf: Self.int16Samples(from: pcm))
            }
        }
        isSpeaking = false
        return samples
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        if !engineReady {
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            try? engine.start()
            player.play()
            engineReady = true
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private static func int16Samples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        if let channel = buffer.int16ChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: frames))
        }
        guard let channel = buffer.floatChannelData else { return [] }
        let floats = UnsafeBufferPointer(start: channel[0], count: frames)
        return floats.map { sample in
            let clipped = max(-1, min(1, sample))
            return Int16(clipped * 32767)
        }
    }
}
