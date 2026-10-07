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

/// Writes BGRA frames to an H.264 QuickTime movie. Frames carry their own timestamps (for
/// ScreenCaptureKit, host-clock time). The movie starts at the first frame and ends at the time
/// passed to `finish`, so a screen that stops changing still records for the full duration
/// (ScreenCaptureKit only delivers frames when something changes). Thread-safe.
/// Spec: docs/04-capture.md §4.9.
public final class VideoFileWriter: @unchecked Sendable {
    public let url: URL
    public let width: Int
    public let height: Int

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let lock = NSLock()
    private var firstTime: CMTime?
    private var lastTime: CMTime?
    private var finished = false
    public private(set) var framesWritten = 0
    public private(set) var framesDropped = 0

    /// `width` and `height` must be even (H.264); use `RegionGeometry.evenPixelSize`.
    public init(url: URL, width: Int, height: Int, framesPerSecond: Int = 30) throws {
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
        framesWritten += 1
        return true
    }

    /// The first frame's timestamp, once one was written.
    public var startTime: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return firstTime
    }

    /// Ends the movie at `endTime` (at least the last frame) and returns its duration in ms.
    public func finish(at endTime: CMTime) async throws -> Int {
        let (start, end) = try lock.withLock { () throws -> (CMTime, CMTime) in
            guard !finished else { throw VideoWriterError.failed("already finished") }
            finished = true
            guard let firstTime, let lastTime else {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                throw VideoWriterError.noFrames
            }
            let end = max(endTime, lastTime)
            input.markAsFinished()
            writer.endSession(atSourceTime: end)
            return (firstTime, end)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoWriterError.failed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        return Int((CMTimeGetSeconds(CMTimeSubtract(end, start)) * 1000).rounded())
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
