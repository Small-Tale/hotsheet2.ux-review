import CoreMedia
import ScreenCaptureKit
import UXReviewKit

/// A finished recording, ready to add to the draft review.
struct RecordedVideo {
    var url: URL
    var pixelWidth: Int
    var pixelHeight: Int
    var durationMs: Int
    var displayScale: Double
}

/// A recording in progress. `stop()` ends it and finalizes the movie.
protocol ActiveRecording: AnyObject, Sendable {
    func stop() async throws -> RecordedVideo
}

/// Records an `SCStream` into a `VideoFileWriter`. Only complete frames are written; idle
/// frames (nothing changed) are skipped, and the movie still ends at the stop time.
/// Spec: docs/04-capture.md §4.9.
final class StreamRecorder: NSObject, SCStreamOutput, SCStreamDelegate, ActiveRecording, @unchecked Sendable {
    static let framesPerSecond = 30

    private let stream: SCStream
    private let writer: VideoFileWriter
    private let scale: Double
    private let queue = DispatchQueue(label: "com.smalltale.uxreview.recording")
    private let onUnexpectedStop: @MainActor () -> Void

    private init(stream: SCStream, writer: VideoFileWriter, scale: Double, onUnexpectedStop: @escaping @MainActor () -> Void) {
        self.stream = stream
        self.writer = writer
        self.scale = scale
        self.onUnexpectedStop = onUnexpectedStop
    }

    @MainActor
    static func start(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        url: URL,
        onUnexpectedStop: @escaping @MainActor () -> Void
    ) async throws -> StreamRecorder {
        let size = RegionGeometry.evenPixelSize(width: configuration.width, height: configuration.height)
        if size != (configuration.width, configuration.height), configuration.sourceRect != .zero {
            // Trim the region by a pixel so the stream and the encoder agree on an even size.
            let region = DisplayRegion(
                sourceRect: configuration.sourceRect, pixelWidth: configuration.width, pixelHeight: configuration.height
            ).evenSized
            configuration.sourceRect = region.sourceRect
        }
        configuration.width = size.width
        configuration.height = size.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.queueDepth = 6
        configuration.showsCursor = true // the pointer shows what the reviewer is doing

        let writer = try VideoFileWriter(url: url, width: size.width, height: size.height, framesPerSecond: framesPerSecond)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let recorder = StreamRecorder(
            stream: stream,
            writer: writer,
            scale: Double(filter.pointPixelScale),
            onUnexpectedStop: onUnexpectedStop
        )
        do {
            try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
            try await stream.startCapture()
        } catch {
            throw ScreenCaptureKitBackend.map(error)
        }
        return recorder
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer,
                  createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        writer.append(pixelBuffer, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_: SCStream, didStopWithError _: Error) {
        Task { @MainActor [onUnexpectedStop] in onUnexpectedStop() }
    }

    func stop() async throws -> RecordedVideo {
        try? await stream.stopCapture()
        // Drain frames already queued, then end the movie now (host clock, like the frames).
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        let durationMs = try await writer.finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
        return RecordedVideo(
            url: writer.url,
            pixelWidth: writer.width,
            pixelHeight: writer.height,
            durationMs: durationMs,
            displayScale: scale
        )
    }
}

/// Feeds 10 fps of test-card frames through the real `VideoFileWriter`, timestamped with the
/// host clock exactly like ScreenCaptureKit frames. Used with `UXREVIEW_CAPTURE_BACKEND=synthetic`.
final class SyntheticRecorder: ActiveRecording, @unchecked Sendable {
    private let writer: VideoFileWriter
    private let scale: Double
    private var feeder: Task<Void, Never>?

    init(url: URL, width: Int, height: Int, scale: Double) throws {
        let size = RegionGeometry.evenPixelSize(width: width, height: height)
        writer = try VideoFileWriter(url: url, width: size.width, height: size.height, framesPerSecond: 10)
        self.scale = scale
        let writer = writer
        feeder = Task.detached {
            var label = 0
            while !Task.isCancelled {
                if let card = ImageFiles.testCard(width: size.width, height: size.height, label: label),
                   let frame = VideoFileWriter.pixelBuffer(from: card, width: size.width, height: size.height) {
                    writer.append(frame, at: CMClockGetTime(CMClockGetHostTimeClock()))
                }
                label += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() async throws -> RecordedVideo {
        feeder?.cancel()
        await feeder?.value
        let durationMs = try await writer.finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
        return RecordedVideo(
            url: writer.url,
            pixelWidth: writer.width,
            pixelHeight: writer.height,
            durationMs: durationMs,
            displayScale: scale
        )
    }
}
