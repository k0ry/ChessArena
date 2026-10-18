import AVFoundation
import Foundation

enum AudioSamples {
    static func resample(_ samples: [Int16], from rate: Double, to target: Double = 44_100) -> [Int16] {
        guard !samples.isEmpty, rate.isFinite, rate > 0 else { return [] }
        if rate == target { return samples }
        return (0..<Int((Double(samples.count) * target / rate).rounded())).map { index in
            let position = Double(index) * rate / target
            let first = min(Int(position), samples.count - 1), next = min(first + 1, samples.count - 1)
            return Int16((Double(samples[first]) + (Double(samples[next]) - Double(samples[first])) * (position - Double(first))).rounded())
        }
    }
}

/// A complete utterance, rendered before its presentation. All samples are mono 44.1 kHz.
public struct PreparedSpeech: Sendable {
    public var text: String
    public var kind: SpeechKind
    public var profile: VoiceProfile
    public var samples: [Int16]
    var status: String?
    var usesFallback = false

    public init(text: String, kind: SpeechKind, profile: VoiceProfile, samples: [Int16]) {
        self.text = text; self.kind = kind; self.profile = profile; self.samples = samples
    }
}

/// FIFO ownership across suspension points. Cancellation removes only the caller's reservation.
@MainActor
final class SpeechGate {
    private var occupied = false
    private var waiting: [(UUID, CheckedContinuation<Bool, Never>)] = []

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if !occupied { occupied = true; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor in
                if let index = self.waiting.firstIndex(where: { $0.0 == id }) {
                    self.waiting.remove(at: index).1.resume(returning: false)
                }
            }
        }
    }

    func release() {
        if waiting.isEmpty { occupied = false }
        else { waiting.removeFirst().1.resume(returning: true) }
    }

    func cancelPending() {
        let pending = waiting; waiting.removeAll()
        pending.forEach { $0.1.resume(returning: false) }
    }
}

@MainActor
final class PreparedAudioPlayer {
    private var player: AVAudioPlayer?
    private var generation = UUID()

    func stop() { generation = UUID(); player?.stop(); player = nil }

    func play(_ samples: [Int16], onStart: () -> Void) async -> [Int16] {
        guard !Task.isCancelled else { return [] }
        let id = UUID()
        generation = id
        // Empty speech still presents the move, including a failed/unavailable system voice.
        guard !samples.isEmpty else { onStart(); return [] }
        do {
            let pcm = samples.withUnsafeBytes { Data($0) }
            let audio = try AVAudioPlayer(data: BroadcastVoice.wav(pcm, sampleRate: 44_100))
            player = audio
            audio.prepareToPlay()
            guard audio.play() else { onStart(); return [] }
            onStart()
            return await withTaskCancellationHandler {
                do {
                    while audio.isPlaying {
                        try await Task.sleep(nanoseconds: 10_000_000)
                        guard generation == id else { return [] }
                    }
                    try Task.checkCancellation()
                    guard generation == id else { return [] }
                    player = nil
                    return samples
                } catch {
                    if generation == id { stop() }
                    return []
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    if self?.generation == id { self?.stop() }
                }
            }
        } catch { onStart(); return [] }
    }
}
