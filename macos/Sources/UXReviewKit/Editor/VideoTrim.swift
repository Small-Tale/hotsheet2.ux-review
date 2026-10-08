import AVFoundation
import CoreGraphics
import Foundation

public enum VideoTrimError: Error, Equatable, CustomStringConvertible {
    case unsupportedFile(String)
    case failed(String)

    public var description: String {
        switch self {
        case let .unsupportedFile(name): "Can't trim \(name): unsupported movie type"
        case let .failed(message): "Trimming the video failed: \(message)"
        }
    }
}

/// Movie file work for the editor: frames at a time (for the canvas and timeline), the expected
/// frame rate (for frame steps), and trimmed exports. Spec: docs/06-annotation-editor.md §6.10.
public enum VideoTrim {
    /// The container type to write for a movie file name, by extension.
    static func fileType(for url: URL) -> AVFileType? {
        switch url.pathExtension.lowercased() {
        case "mov", "qt": .mov
        case "mp4": .mp4
        case "m4v": .m4v
        default: nil
        }
    }

    /// Writes `source` to `destination` (replacing it), cut to `range` (ms of the source) and
    /// scaled to `size` (display pixels, aspect ratio the caller's), in one export. Either may be
    /// nil: no cut, or the source's size. Re-encodes at the highest quality so the cut is
    /// frame-accurate rather than snapped to key frames. Blocks until the export finishes.
    /// Submitting uses it for trims and AI downscaling (docs/07 §7.5, `HS2-PT8PM6`).
    public static func export(_ source: URL, range: TimeRange?, size: PixelSize? = nil, to destination: URL) throws {
        guard let fileType = fileType(for: destination) else { throw VideoTrimError.unsupportedFile(destination.lastPathComponent) }
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoTrimError.failed("no export session for \(source.lastPathComponent)")
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".trim-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        session.outputURL = temporary
        session.outputFileType = fileType
        if let range {
            session.timeRange = CMTimeRange(
                start: CMTime(value: CMTimeValue(range.startMs), timescale: 1000),
                end: CMTime(value: CMTimeValue(range.endMs), timescale: 1000)
            )
        }
        if let size {
            let box = CompositionBox()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    box.result = try await .success(scalingComposition(asset, to: size))
                } catch {
                    box.result = .failure(error)
                }
                done.signal()
            }
            done.wait()
            switch box.result {
            case let .success(composition): session.videoComposition = composition
            case let .failure(error): throw VideoTrimError.failed("can't scale \(source.lastPathComponent): \(error)")
            case nil: throw VideoTrimError.failed("can't scale \(source.lastPathComponent)")
            }
        }
        let done = DispatchSemaphore(value: 0)
        let box = SessionBox(session)
        box.session.exportAsynchronously { done.signal() }
        done.wait()
        guard box.session.status == .completed else {
            throw VideoTrimError.failed(box.session.error?.localizedDescription ?? "status \(box.session.status.rawValue)")
        }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    }

    /// A composition drawing the movie's video track (as displayed: its preferred transform
    /// applied) scaled to fill `size`, at the movie's frame rate (the recorded rate, else the
    /// nominal one, else 30 fps).
    static func scalingComposition(_ asset: AVURLAsset, to size: PixelSize) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoTrimError.failed("no video track")
        }
        let (natural, preferred, nominal) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        let display = CGRect(origin: .zero, size: natural).applying(preferred)
        guard display.width > 0, display.height > 0 else { throw VideoTrimError.failed("empty video track") }
        let rate = await recordedFrameRate(asset) ?? (nominal.isFinite && nominal >= 1 ? Double(nominal) : 30)
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(renderTransform(preferred: preferred, display: display, to: size), at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: duration)
        ))
        return AVVideoComposition(configuration: .init(
            frameDuration: CMTime(value: 1000, timescale: CMTimeScale((max(rate, 1) * 1000).rounded())),
            instructions: [instruction],
            renderSize: CGSize(width: size.width, height: size.height)
        ))
    }

    /// Natural track pixels → the output frame: the preferred transform (moved so the displayed
    /// frame starts at 0, 0), then a scale from the displayed size to `size`.
    static func renderTransform(preferred: CGAffineTransform, display: CGRect, to size: PixelSize) -> CGAffineTransform {
        preferred
            .concatenating(CGAffineTransform(translationX: -display.minX, y: -display.minY))
            .concatenating(CGAffineTransform(scaleX: CGFloat(size.width) / display.width, y: CGFloat(size.height) / display.height))
    }

    /// Carries the composition out of the detached task that loads it.
    private final class CompositionBox: @unchecked Sendable {
        var result: Result<AVVideoComposition, Error>?
    }

    /// The movie's expected frame rate, for frame steps on a uniform grid (docs/06 §6.10,
    /// `FrameGrid.expectedRate`): the rate a UX Review recording stored
    /// (`VideoFileWriter.frameRateMetadataKey`), else the nominal rate when the samples sit on it,
    /// else a variable-rate movie's interval snapped to a standard rate. Only metadata and the
    /// sample table (`AVSampleCursor`) are read, not the frames, and the sample table only when
    /// no rate was stored. Nil without a readable video track or a usable rate. A long movie
    /// without a stored rate takes a while (every sample is visited), so the editor window loads
    /// it in the background (`EditorSession.FrameRateLoading`, `HS2-F999CM`).
    public static func loadFrameRate(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        if let recorded = await recordedFrameRate(asset), recorded >= 1 { return recorded }
        let rate = try? await track.load(.nominalFrameRate)
        let nominal = rate.flatMap { $0.isFinite && $0 > 0 ? Double($0) : nil }
        let duration = try? await asset.load(.duration)
        let durationMs = duration.flatMap { $0.isNumeric ? Int((CMTimeGetSeconds($0) * 1000).rounded()) : nil }
        return await FrameGrid.expectedRate(sampleTimesMs: sampleTimesMs(track), durationMs: durationMs, nominalRate: nominal)
    }

    /// `loadFrameRate(of:)`, blocking until AVFoundation has loaded it.
    public static func frameRate(of url: URL) -> Double? {
        blocking { await loadFrameRate(of: url) }
    }

    /// The frame rate `VideoFileWriter` stored in the movie, if any.
    static func recordedFrameRate(_ asset: AVURLAsset) async -> Double? {
        let items = await (try? asset.load(.metadata)) ?? []
        guard let item = items.first(where: {
            $0.keySpace == .quickTimeMetadata && ($0.key as? String) == VideoFileWriter.frameRateMetadataKey
        }) else { return nil }
        return await (try? item.load(.numberValue))?.doubleValue
    }

    /// Most samples `sampleTimesMs` reads (about 2.3 hours at 60 fps); longer movies step at
    /// their nominal rate.
    static let sampleLimit = 500_000

    /// Presentation times (ms on the movie timeline) of the track's samples, in decode order:
    /// the sample table's media times mapped through each edit of the track's edit list (scaled
    /// by its rate; samples outside every edit are left out). An edit's own start is not a frame
    /// time: when it starts inside a frame, that frame's real interval began earlier, and a short
    /// gap there would skew `FrameGrid.expectedRate`. Nil when the track can't provide a sample
    /// cursor or has more than `sampleLimit` samples.
    static func sampleTimesMs(_ track: AVAssetTrack) async -> [Double]? {
        guard await (try? track.load(.canProvideSampleCursors)) == true,
              let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return nil }
        var media: [CMTime] = []
        repeat {
            media.append(cursor.presentationTimeStamp)
            if media.count > sampleLimit { return nil }
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        let segments = await (try? track.load(.segments)) ?? []
        let mappings = segments.filter { !$0.isEmpty }.map(\.timeMapping)
        guard !mappings.isEmpty else {
            return media.map { CMTimeGetSeconds($0) * 1000 }
        }
        var times: [Double] = []
        for mapping in mappings {
            let source = mapping.source
            let target = mapping.target
            let sourceSeconds = CMTimeGetSeconds(source.duration)
            guard sourceSeconds > 0 else { continue }
            let scale = CMTimeGetSeconds(target.duration) / sourceSeconds
            let targetStart = CMTimeGetSeconds(target.start)
            for time in media where source.containsTime(time) {
                times.append((targetStart + CMTimeGetSeconds(CMTimeSubtract(time, source.start)) * scale) * 1000)
            }
        }
        return times
    }

    /// Runs `read` in a detached task, blocking until it finishes.
    private static func blocking<Value: Sendable>(_ read: @escaping @Sendable () async -> Value?) -> Value? {
        let box = ResultBox<Value>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await read()
            done.signal()
        }
        done.wait()
        return box.value
    }

    /// Carries the loaded value out of the detached task; written before the semaphore signals,
    /// read after it.
    private final class ResultBox<Value>: @unchecked Sendable {
        var value: Value?
    }

    /// Copies `source` over `destination` byte for byte (restoring a kept original).
    public static func restore(_ source: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".restore-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    }

    /// AVAssetExportSession isn't Sendable; it is only touched before the export starts and
    /// after its completion signals.
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }
}

/// Frames of one movie at given times, cached. Not thread-safe; the editor uses it from one thread.
final class VideoFrames {
    let url: URL
    private let generator: AVAssetImageGenerator
    private var cache: [Int: CGImage] = [:]
    private var order: [Int] = []
    static let cacheLimit = 48

    init(url: URL) {
        self.url = url
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
    }

    /// The frame showing at `millis`; past the last frame, the last frame.
    func frame(atMs millis: Int) -> CGImage? {
        if let image = cache[millis] { return image }
        let time = CMTime(value: CMTimeValue(max(millis, 0)), timescale: 1000)
        var image = try? generator.copyCGImage(at: time, actualTime: nil)
        if image == nil, millis > 0 {
            // The clip's end time has no frame of its own; show the frame just before it.
            generator.requestedTimeToleranceBefore = .positiveInfinity
            image = try? generator.copyCGImage(at: time, actualTime: nil)
            generator.requestedTimeToleranceBefore = .zero
        }
        guard let image else { return nil }
        cache[millis] = image
        order.append(millis)
        if order.count > Self.cacheLimit { cache[order.removeFirst()] = nil }
        return image
    }
}
