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
    public let directory: URL
    public private(set) var isOpen = false
    public private(set) var moves: [AcceptedMove] = []
    public private(set) var journal: [JournalEntry] = []
    public let whiteName: String
    public let blackName: String
    private var writer: ArenaVideoWriter?
    private var result = "*"

    public init(directory: URL, whiteName: String, blackName: String) {
        self.directory = directory
        self.whiteName = whiteName
        self.blackName = blackName
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

    public func record(move: AcceptedMove, clock: TimeInterval) {
        moves.append(move)
        if !move.taunt.isEmpty {
            journal.append(JournalEntry(kind: "taunt", text: move.taunt, clock: clock, move: move.move.uci))
        }
    }

    public func record(line: SpokenLine) {
        guard line.kind != .tone else { return }
        journal.append(JournalEntry(kind: line.kind.rawValue, text: line.text, clock: line.clock, move: nil))
    }

    public func markResult(_ end: GameEnd?) {
        guard let end else {
            result = "*"
            return
        }
        switch end.winner {
        case .white:
            result = "1-0"
        case .black:
            result = "0-1"
        case nil:
            result = "1/2-1/2"
        }
    }

    public func append(pixelBuffer: CVPixelBuffer) {
        writer?.append(pixelBuffer: pixelBuffer)
    }

    public func appendAudio(_ samples: [Int16]) {
        try? writer?.appendPCM(samples)
    }

    public func close() async throws {
        try await finish(end: nil)
    }

    public func finish(end: GameEnd?) async throws {
        guard isOpen else { return }
        isOpen = false
        let finishingWriter = writer
        writer = nil
        markResult(end)
        try writeSidecars()
        try await finishingWriter?.finish()
    }

    public func writeSidecars() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try pgnText().write(to: pgnURL, atomically: true, encoding: .utf8)
        let data = try JSONEncoder().encode(journal)
        try data.write(to: journalURL)
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

    func append(pixelBuffer: CVPixelBuffer) {
        guard started, videoInput.isReadyForMoreMediaData else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: videoTime) {
            videoTime = CMTimeAdd(videoTime, CMTime(value: 1, timescale: 30))
        }
    }

    func appendPCM(_ samples: [Int16]) throws {
        guard started, !samples.isEmpty, audioInput.isReadyForMoreMediaData else { return }
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
            presentationTimeStamp: audioTime,
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
        if audioInput.append(sampleBuffer) {
            audioTime = CMTimeAdd(audioTime, CMTime(value: CMTimeValue(samples.count), timescale: 44_100))
        }
    }

    func finish() async throws {
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
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
