import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public struct JournalEntry: Codable, Equatable, Sendable {
    public var kind: String
    public var text: String
    public var clock: Double
    public var move: String?
}

public enum ArchiveError: Error {
    case writer(String)
}

public final class MatchArchive {
    public let roundID: UUID
    public private(set) var diagnosticError: String?
    private var termination = "unterminated"
    public let directory: URL
    public private(set) var isOpen = false
    public private(set) var moves: [AcceptedMove] = []
    public private(set) var journal: [JournalEntry] = []
    public let whiteName: String
    public let blackName: String
    private var writer: ArenaVideoWriter?
    private var result = "*"

    public init(directory: URL, whiteName: String, blackName: String, roundID: UUID = UUID()) {
        self.roundID = roundID
        self.directory = directory
        self.whiteName = whiteName
        self.blackName = blackName
    }

    public func restore(moves: [AcceptedMove], journal: [JournalEntry], end: GameEnd?, position: Position? = nil) {
        precondition(!isOpen)
        self.moves = moves
        self.journal = journal
        markResult(end, position: position)
    }

    public func writeParticipants(white: Seat, black: Seat) throws {
        struct Participant: Encodable { var provider: String; var model: String; var side: Side }
        struct Metadata: Encodable { var roundID: UUID; var participants: [Participant] }
        let metadata = Metadata(roundID: roundID, participants: [white, black].map {
            Participant(provider: DeepSeekAPI.redact($0.name, key: $0.apiKey), model: DeepSeekAPI.redact($0.model, key: $0.apiKey), side: $0.side)
        })
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("participants.json"), options: .atomic)
    }

    public var diagnosticsURL: URL { directory.appendingPathComponent("diagnostics.jsonl") }

    /// Append every event immediately so an interrupted video export cannot erase the diagnosis.
    public func record(diagnostic: MatchDiagnostic) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var data = try JSONEncoder().encode(diagnostic)
            data.append(0x0a)
            if !FileManager.default.fileExists(atPath: diagnosticsURL.path) {
                try data.write(to: diagnosticsURL, options: .withoutOverwriting)
            } else {
                let file = try FileHandle(forWritingTo: diagnosticsURL)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: data)
                try file.synchronize()
            }
            try writeSidecars()
        } catch {
            diagnosticError = "Не удалось сохранить диагностику партии. Проверьте папку архива и свободное место."
        }
    }

    public var videoURL: URL { directory.appendingPathComponent("match.mp4") }
    public var pgnURL: URL { directory.appendingPathComponent("game.pgn") }
    public var journalURL: URL { directory.appendingPathComponent("commentary.json") }

    public func open() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let video = try ArenaVideoWriter(url: videoURL)
        video.start()
        writer = video
        isOpen = true
    }

    public func record(move: AcceptedMove, clock: TimeInterval, includeTaunt: Bool = true) {
        moves.append(move)
        if includeTaunt, !move.taunt.isEmpty {
            journal.append(JournalEntry(kind: "taunt", text: move.taunt, clock: clock, move: move.move.uci))
        }
    }

    public func record(line: SpokenLine, move: String? = nil) {
        guard line.kind != .tone else { return }
        journal.append(JournalEntry(kind: line.kind.rawValue, text: line.text, clock: line.clock, move: move))
    }

    public func markResult(_ end: GameEnd?, position: Position? = nil) {
        let board = moves.last.flatMap { Position.position(fen: $0.fenAfter) } ?? position ?? .standard()
        guard let end, board.gameEnd == end else {
            result = "*"
            termination = "unterminated"
            return
        }
        termination = end == .stalemate ? "stalemate" : "checkmate"
        switch end.winner {
        case .white:
            result = "1-0"
        case .black:
            result = "0-1"
        case nil:
            result = "1/2-1/2"
        }
    }

    public func append(pixelBuffer: CVPixelBuffer, at time: TimeInterval? = nil) {
        writer?.append(pixelBuffer: pixelBuffer, at: time)
    }

    public func appendAudio(_ samples: [Int16], sampleRate: Double = 44_100, at time: TimeInterval? = nil) {
        try? writer?.appendPCM(AudioSamples.resample(samples, from: sampleRate), at: time)
    }

    public func appendSilence(until time: TimeInterval) {
        try? writer?.appendSilence(until: time)
    }

    public func close() async throws {
        try await finish(end: nil)
    }

    public func finish(end: GameEnd?, position: Position? = nil) async throws {
        guard isOpen else { return }
        isOpen = false
        let finishingWriter = writer
        writer = nil
        markResult(end, position: position)
        try writeSidecars()
        try await finishingWriter?.finish()
    }

    public func writeSidecars() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try pgnText().write(to: pgnURL, atomically: true, encoding: .utf8)
        let data = try JSONEncoder().encode(journal)
        try data.write(to: journalURL, options: .atomic)
    }

    public func pgnText() -> String {
        var body = ""
        for (index, move) in moves.enumerated() {
            if index % 2 == 0 {
                body += "\(index / 2 + 1). "
            }
            body += move.san
            if !move.taunt.isEmpty {
                let safe = move.taunt.replacingOccurrences(of: "}", with: "")
                body += " {\(safe)}"
            }
            body += " "
        }
        body += result
        return """
        [Event "ChessArena"]
        [Site "ChessArena"]
        [White "\(whiteName)"]
        [Black "\(blackName)"]
        [Result "\(result)"]
        [Termination "\(termination)"]
        [Round "\(roundID.uuidString)"]

        \(body)
        """
    }
}

final class ArenaVideoWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput
    private var videoTime = CMTime.zero
    private var audioTime = CMTime.zero
    private var pendingAudio: [CMSampleBuffer] = []
    private var pendingVideo: [(CVPixelBuffer, CMTime)] = []
    private var audioFailure = false
    private var videoFailure = false
    private var started = false

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: StageMetrics.width,
            AVVideoHeightKey: StageMetrics.height,
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = 30
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: StageMetrics.width,
                kCVPixelBufferHeightKey as String: StageMetrics.height,
            ]
        )
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000,
        ])
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw ArchiveError.writer("inputs rejected")
        }
        writer.add(videoInput)
        writer.add(audioInput)
    }

    func start() {
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        started = true
    }

    func append(pixelBuffer: CVPixelBuffer, at time: TimeInterval? = nil) {
        flushAudio()
        guard started else { return }
        let timestamp = time.map { CMTime(seconds: max(0, $0), preferredTimescale: 600) } ?? videoTime
        guard CMTimeCompare(timestamp, videoTime) >= 0 else { return }
        pendingVideo.append((pixelBuffer, timestamp))
        // AAC interleaving can hold the video input for about a second. Retain those frames;
        // bound memory if an encoder remains stalled much longer than that.
        if pendingVideo.count > 60 { pendingVideo.removeFirst() }
        videoTime = CMTimeAdd(timestamp, CMTime(value: 1, timescale: time == nil ? 30 : 600))
        flushVideo()
    }

    func appendPCM(_ samples: [Int16], at time: TimeInterval? = nil) throws {
        guard started, !samples.isEmpty else { return }
        // Preserve thinking/synthesis gaps instead of concatenating voices from time zero.
        let requested = time.map { CMTime(seconds: max(0, $0), preferredTimescale: 44_100) } ?? audioTime
        // AAC encoding consumes continuous PCM. Explicit silence preserves gaps reliably;
        // sparse input timestamps alone can be collapsed by the encoder.
        try appendSilence(until: requested.seconds)
        let timestamp = CMTimeMaximum(audioTime, requested)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard formatStatus == noErr, let format else {
            throw ArchiveError.writer("audio format \(formatStatus)")
        }
        let dataSize = samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &block
        )
        guard blockStatus == kCMBlockBufferNoErr, let block else {
            throw ArchiveError.writer("block \(blockStatus)")
        }
        let copyStatus = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw ArchiveError.writer("copy \(copyStatus)")
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 44_100),
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: samples.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw ArchiveError.writer("sample \(sampleStatus)")
        }
        pendingAudio.append(sampleBuffer)
        audioTime = CMTimeAdd(timestamp, CMTime(value: CMTimeValue(samples.count), timescale: 44_100))
        flushAudio()
    }

    func appendSilence(until time: TimeInterval) throws {
        guard started else { return }
        var silence = max(0, Int(((time - audioTime.seconds) * 44_100).rounded()))
        while silence > 0 {
            let count = min(silence, 44_100)
            try appendPCM(Array(repeating: 0, count: count))
            silence -= count
        }
    }

    private func flushAudio() {
        while !pendingAudio.isEmpty, audioInput.isReadyForMoreMediaData {
            let buffer = pendingAudio.removeFirst()
            if !audioInput.append(buffer) { audioFailure = true; break }
        }
    }

    private func flushVideo() {
        while !pendingVideo.isEmpty, videoInput.isReadyForMoreMediaData {
            let (buffer, timestamp) = pendingVideo.removeFirst()
            if !adaptor.append(buffer, withPresentationTime: timestamp) { videoFailure = true; break }
        }
    }

    func finish() async throws {
        var audioFinished = false, videoFinished = false
        while writer.status == .writing, !audioFailure, !videoFailure {
            flushAudio()
            flushVideo()
            if pendingAudio.isEmpty, !audioFinished { audioInput.markAsFinished(); audioFinished = true }
            if pendingVideo.isEmpty, !videoFinished { videoInput.markAsFinished(); videoFinished = true }
            if audioFinished && videoFinished { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        if !audioFinished { audioInput.markAsFinished() }
        if !videoFinished { videoInput.markAsFinished() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed, !audioFailure, !videoFailure else {
            throw ArchiveError.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }
}

public enum FrameBuffer {
    public static func make(width: Int = StageMetrics.width, height: Int = StageMetrics.height, fill: UInt8 = 18) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        let pixel = buffer!
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            memset(base, Int32(fill), CVPixelBufferGetDataSize(pixel))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        return pixel
    }
}
