import AVFoundation
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
    /// Whether the movie has a narration track (narration was on and audio arrived).
    var hasNarration = false
}

/// A recording in progress. `stop()` ends it and finalizes the movie.
protocol ActiveRecording: AnyObject, Sendable {
    func stop() async throws -> RecordedVideo
}

/// Records an `SCStream` into a `VideoFileWriter`, plus the microphone when narrating. Only
/// complete frames are written; idle frames (nothing changed) are skipped, and the movie still
/// ends at the stop time. Spec: docs/04-capture.md §4.9.
final class StreamRecorder: NSObject, SCStreamOutput, SCStreamDelegate, ActiveRecording, @unchecked Sendable {
    static let framesPerSecond = 30

    private let stream: SCStream
    private let writer: VideoFileWriter
    private let microphone: MicrophoneRecorder?
    private let scale: Double
    private let queue = DispatchQueue(label: "com.smalltale.uxreview.recording")
    private let onUnexpectedStop: @MainActor () -> Void

    private init(
        stream: SCStream,
        writer: VideoFileWriter,
        microphone: MicrophoneRecorder?,
        scale: Double,
        onUnexpectedStop: @escaping @MainActor () -> Void
    ) {
        self.stream = stream
        self.writer = writer
        self.microphone = microphone
        self.scale = scale
        self.onUnexpectedStop = onUnexpectedStop
    }

    @MainActor
    static func start(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        url: URL,
        narration: Bool,
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

        let writer = try VideoFileWriter(
            url: url,
            width: size.width,
            height: size.height,
            framesPerSecond: framesPerSecond,
            audio: narration ? .narration : nil
        )
        let microphone = narration ? try MicrophoneRecorder(writer: writer) : nil
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let recorder = StreamRecorder(
            stream: stream,
            writer: writer,
            microphone: microphone,
            scale: Double(filter.pointPixelScale),
            onUnexpectedStop: onUnexpectedStop
        )
        // The microphone runs first: its audio before the first frame is dropped by the writer.
        await microphone?.start()
        do {
            try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
            try await stream.startCapture()
        } catch {
            await microphone?.stop()
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
        await microphone?.stop()
        // Drain frames already queued, then end the movie now (host clock, like the frames).
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        let durationMs = try await writer.finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
        return RecordedVideo(
            url: writer.url,
            pixelWidth: writer.width,
            pixelHeight: writer.height,
            durationMs: durationMs,
            displayScale: scale,
            hasNarration: writer.hasAudio
        )
    }
}

/// The default microphone, as LPCM, into the writer's narration track. Timestamps are converted
/// from the capture session's clock to the host clock that ScreenCaptureKit frames use, so the
/// tracks line up. If the microphone fails or is unplugged mid-recording, the video carries on
/// and the narration simply ends there. Spec: docs/04-capture.md §4.9.
final class MicrophoneRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let writer: VideoFileWriter
    private let queue = DispatchQueue(label: "com.smalltale.uxreview.microphone")
    private let hostClock = CMClockGetHostTimeClock()

    init(writer: VideoFileWriter) throws {
        self.writer = writer
        super.init()
        guard let device = AVCaptureDevice.default(for: .audio) else { throw CaptureFailure.microphone(.unavailable) }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureFailure.failed("the microphone could not be opened: \(error.localizedDescription)")
        }
        let output = AVCaptureAudioDataOutput()
        // Mono 48 kHz 16-bit LPCM, whatever the device's native format; the writer encodes AAC.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioTrackFormat.narration.sampleRate,
            AVNumberOfChannelsKey: AudioTrackFormat.narration.channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CaptureFailure.failed("the microphone could not be attached to the recording")
        }
        session.addInput(input)
        session.addOutput(output)
    }

    /// `startRunning`/`stopRunning` block, so they run on the microphone queue.
    func start() async {
        // AVCaptureSession isn't Sendable; it is only touched on the microphone queue here.
        nonisolated(unsafe) let session = session
        await withCheckedContinuation { continuation in
            queue.async {
                session.startRunning()
                continuation.resume()
            }
        }
    }

    func stop() async {
        // AVCaptureSession isn't Sendable; it is only touched on the microphone queue here.
        nonisolated(unsafe) let session = session
        await withCheckedContinuation { continuation in
            queue.async {
                session.stopRunning()
                continuation.resume() // buffers already delivered on this queue ran before this
            }
        }
    }

    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        writer.appendAudio(Self.retimed(sampleBuffer, from: session.synchronizationClock, to: hostClock) ?? sampleBuffer)
    }

    /// The buffer re-stamped on `target` (nil when the clocks already agree or retiming fails).
    static func retimed(_ buffer: CMSampleBuffer, from source: CMClock?, to target: CMClock) -> CMSampleBuffer? {
        guard let source, source != target else { return nil }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        let converted = CMSyncConvertTime(time, from: source, to: target)
        guard converted.isNumeric, converted != time else { return nil }
        let timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(buffer),
            presentationTimeStamp: converted,
            decodeTimeStamp: .invalid
        )
        return try? CMSampleBuffer(copying: buffer, withNewTiming: [timing])
    }
}

/// Feeds 10 fps of test-card frames through the real `VideoFileWriter`, timestamped with the
/// host clock exactly like ScreenCaptureKit frames, and with narration a 440 Hz tone in 100 ms
/// buffers starting at the first frame. Used with `UXREVIEW_CAPTURE_BACKEND=synthetic`.
final class SyntheticRecorder: ActiveRecording, @unchecked Sendable {
    private let writer: VideoFileWriter
    private let scale: Double
    private var feeders: [Task<Void, Never>] = []

    init(url: URL, width: Int, height: Int, scale: Double, narration: Bool = false) throws {
        let size = RegionGeometry.evenPixelSize(width: width, height: height)
        writer = try VideoFileWriter(
            url: url,
            width: size.width,
            height: size.height,
            framesPerSecond: 10,
            audio: narration ? .narration : nil
        )
        self.scale = scale
        let writer = writer
        feeders.append(Task.detached {
            var label = 0
            while !Task.isCancelled {
                if let card = ImageFiles.testCard(width: size.width, height: size.height, label: label),
                   let frame = VideoFileWriter.pixelBuffer(from: card, width: size.width, height: size.height) {
                    writer.append(frame, at: CMClockGetTime(CMClockGetHostTimeClock()))
                }
                label += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        })
        if narration { feeders.append(Task.detached { await Self.feedTone(to: writer) }) }
    }

    /// Contiguous tone buffers from the first frame on, each appended once its 100 ms have
    /// passed on the host clock (as a microphone would deliver them).
    private static func feedTone(to writer: VideoFileWriter) async {
        let samples = Int(SyntheticAudio.sampleRate / 10)
        var start: CMTime?
        while start == nil, !Task.isCancelled {
            start = writer.startTime
            if start == nil { try? await Task.sleep(for: .milliseconds(5)) }
        }
        guard let start else { return }
        var index = 0
        while !Task.isCancelled {
            let time = CMTimeAdd(start, CMTime(value: CMTimeValue(index * samples), timescale: CMTimeScale(SyntheticAudio.sampleRate)))
            let due = CMTimeGetSeconds(time) + 0.1 - CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            if due > 0 { try? await Task.sleep(for: .milliseconds(Int(due * 1000) + 1)) }
            guard !Task.isCancelled else { return }
            if let buffer = SyntheticAudio.toneBuffer(at: time, firstSample: index * samples, count: samples) {
                writer.appendAudio(buffer)
            }
            index += 1
        }
    }

    func stop() async throws -> RecordedVideo {
        for feeder in feeders {
            feeder.cancel()
        }
        for feeder in feeders {
            await feeder.value
        }
        let durationMs = try await writer.finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
        return RecordedVideo(
            url: writer.url,
            pixelWidth: writer.width,
            pixelHeight: writer.height,
            durationMs: durationMs,
            displayScale: scale,
            hasNarration: writer.hasAudio
        )
    }
}
