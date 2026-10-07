import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public enum VideoWriterError: Error, Equatable, CustomStringConvertible {
    case cannotCreate(String)
    case noFrames
    case failed(String)

    public var description: String {
        switch self {
        case let .cannotCreate(message): "Cannot create the video file: \(message)"
        case .noFrames: "No frames were recorded."
        case let .failed(message): "Writing the video failed: \(message)"
        }
    }
}

/// The optional narration track of a recording: AAC, encoded from whatever LPCM the microphone
/// (or the synthetic source) delivers. Spec: docs/04-capture.md §4.9.
public struct AudioTrackFormat: Equatable, Sendable {
    public var sampleRate: Double
    public var channels: Int
    public var bitRate: Int

    public init(sampleRate: Double = 48000, channels: Int = 1, bitRate: Int = 96000) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitRate = bitRate
    }

    /// Mono speech at 48 kHz.
    public static let narration = AudioTrackFormat()
}

/// Writes BGRA frames to an H.264 QuickTime movie, plus an optional AAC narration track. Frames
/// and audio carry their own timestamps on one clock (the host clock). The movie starts at the
/// first video frame and ends at the time passed to `finish`, so a screen that stops changing
/// still records for the full duration (ScreenCaptureKit only delivers frames when something
/// changes). Audio from before the first frame is dropped, and audio after the end is trimmed
/// with the video, so the tracks stay in sync. Thread-safe. Spec: docs/04-capture.md §4.9.
public final class VideoFileWriter: @unchecked Sendable {
    public let url: URL
    public let width: Int
    public let height: Int

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let lock = NSLock()
    private var firstTime: CMTime?
    private var lastTime: CMTime?
    /// The last written frame, repeated at the end time so the video track itself reaches it.
    private var lastFrame: CVPixelBuffer?
    private var finished = false
    public private(set) var framesWritten = 0
    public private(set) var framesDropped = 0
    private var lastAudioTime: CMTime?
    public private(set) var audioBuffersWritten = 0
    public private(set) var audioBuffersDropped = 0

    /// `width` and `height` must be even (H.264); use `RegionGeometry.evenPixelSize`. With
    /// `audio`, the movie also gets a narration track fed by `appendAudio`.
    public init(url: URL, width: Int, height: Int, framesPerSecond: Int = 30, audio: AudioTrackFormat? = nil) throws {
        guard width >= 2, height >= 2, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw VideoWriterError.cannotCreate("size \(width)×\(height) must be even and at least 2×2")
        }
        self.url = url
        self.width = width
        self.height = height
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw VideoWriterError.cannotCreate(error.localizedDescription)
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw VideoWriterError.cannotCreate("the writer rejected the video input") }
        writer.add(input)
        if let audio {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: audio.channels,
                AVEncoderBitRateKey: audio.bitRate,
            ])
            audioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(audioInput) else { throw VideoWriterError.cannotCreate("the writer rejected the audio input") }
            writer.add(audioInput)
            self.audioInput = audioInput
        } else {
            audioInput = nil
        }
        guard writer.startWriting() else {
            throw VideoWriterError.cannotCreate(writer.error?.localizedDescription ?? "startWriting failed")
        }
    }

    /// Appends one frame. Frames that arrive while the encoder is busy, out of order, or after
    /// `finish` are dropped (and counted) rather than blocking the capture queue.
    @discardableResult
    public func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, writer.status == .writing else { framesDropped += 1; return false }
        if firstTime == nil {
            writer.startSession(atSourceTime: time)
            firstTime = time
        }
        if let lastTime, time <= lastTime { framesDropped += 1; return false }
        guard input.isReadyForMoreMediaData, adaptor.append(pixelBuffer, withPresentationTime: time) else {
            framesDropped += 1
            return false
        }
        lastTime = time
        lastFrame = pixelBuffer
        framesWritten += 1
        return true
    }

    /// Appends one buffer of LPCM narration audio, timestamped on the same clock as the frames.
    /// Dropped (and counted) when there is no audio track, before the first video frame (the
    /// movie starts there), out of order, while the encoder is busy, or after `finish`.
    @discardableResult
    public func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let audioInput, !finished, writer.status == .writing, let firstTime, time.isNumeric, time >= firstTime else {
            audioBuffersDropped += 1
            return false
        }
        if let lastAudioTime, time <= lastAudioTime { audioBuffersDropped += 1; return false }
        guard audioInput.isReadyForMoreMediaData, audioInput.append(sampleBuffer) else {
            audioBuffersDropped += 1
            return false
        }
        lastAudioTime = time
        audioBuffersWritten += 1
        return true
    }

    /// Whether the movie has narration audio (an audio track with at least one buffer).
    public var hasAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return audioBuffersWritten > 0
    }

    /// The first frame's timestamp, once one was written.
    public var startTime: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return firstTime
    }

    /// Ends the movie at `endTime` (at least the last frame) and returns its duration in ms.
    public func finish(at endTime: CMTime) async throws -> Int {
        let (start, end, holdFrame) = try lock.withLock { () throws -> (CMTime, CMTime, CVPixelBuffer?) in
            guard !finished else { throw VideoWriterError.failed("already finished") }
            finished = true // no more appends from here on, so the rest can run unlocked
            guard let firstTime, let lastTime else {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                throw VideoWriterError.noFrames
            }
            let end = max(endTime, lastTime)
            defer { lastFrame = nil }
            return (firstTime, end, end > lastTime ? lastFrame : nil)
        }
        // Hold the last frame until the end: repeat it at the end time (endSession trims it to
        // zero length). Without this, a movie with an audio track ends at its last sample rather
        // than at the stop time, e.g. when the screen stopped changing and the audio ended early.
        if let holdFrame {
            for _ in 0 ..< 400 where !input.isReadyForMoreMediaData {
                try? await Task.sleep(for: .milliseconds(5))
            }
            if input.isReadyForMoreMediaData { adaptor.append(holdFrame, withPresentationTime: end) }
        }
        input.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoWriterError.failed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        return Int((CMTimeGetSeconds(CMTimeSubtract(end, start)) * 1000).rounded())
    }

    /// Reads a movie's audio track, for verification: nil when there is none, else where its
    /// media starts on the movie timeline and how long it lasts (ms).
    public static func inspectAudio(_ url: URL) async throws -> (startMs: Int, durationMs: Int)? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let media = try await track.load(.segments).filter { !$0.isEmpty }.map(\.timeMapping.target)
        guard let first = media.first, let last = media.last else { return nil }
        let start = CMTimeGetSeconds(first.start)
        let end = CMTimeGetSeconds(last.end)
        return (Int((start * 1000).rounded()), Int(((end - start) * 1000).rounded()))
    }

    /// A BGRA pixel buffer holding `image`, for synthetic frames and tests.
    public static func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// Reads a movie's duration (ms) and video track size, for verification.
    public static func inspect(_ url: URL) async throws -> (durationMs: Int, width: Int, height: Int) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoWriterError.noFrames }
        let size = try await track.load(.naturalSize)
        return (Int((CMTimeGetSeconds(duration) * 1000).rounded()), Int(size.width), Int(size.height))
    }
}
