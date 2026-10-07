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

/// Movie file work for the editor: frames at a time (for the canvas and timeline) and trimmed
/// exports. Spec: docs/06-annotation-editor.md §6.10.
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

    /// Writes the part of `source` from `range.startMs` to `range.endMs` to `destination`
    /// (replacing it). Re-encodes at the highest quality so the cut is frame-accurate rather
    /// than snapped to key frames. Blocks until the export finishes.
    public static func export(_ source: URL, range: TimeRange, to destination: URL) throws {
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
        session.timeRange = CMTimeRange(
            start: CMTime(value: CMTimeValue(range.startMs), timescale: 1000),
            end: CMTime(value: CMTimeValue(range.endMs), timescale: 1000)
        )
        let done = DispatchSemaphore(value: 0)
        let box = SessionBox(session)
        box.session.exportAsynchronously { done.signal() }
        done.wait()
        guard box.session.status == .completed else {
            throw VideoTrimError.failed(box.session.error?.localizedDescription ?? "status \(box.session.status.rawValue)")
        }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    }

    /// The movie's frame rate (its video track's nominal frames per second), for frame stepping.
    /// Nil when the file has no readable video track. Blocks until AVFoundation has loaded it.
    public static func frameRate(of url: URL) -> Double? {
        let box = RateBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let rate = try? await track.load(.nominalFrameRate), rate.isFinite, rate > 0 {
                box.rate = Double(rate)
            }
            done.signal()
        }
        done.wait()
        return box.rate
    }

    /// Carries the loaded rate out of the detached task; written before the semaphore signals,
    /// read after it.
    private final class RateBox: @unchecked Sendable {
        var rate: Double?
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
