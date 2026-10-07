import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// Playing a video in the editor (docs/06-annotation-editor.md §6.10). An `AVPlayer` on the
/// session's base movie, offset by the current trim, so it plays exactly the clip the canvas
/// scrubs. The playhead is millis into the clip as trimmed. While playing, `frame()` returns the
/// video frame the player is showing, which the canvas draws (annotations on top).
public final class VideoPlayback {
    /// The movie playing (the session's base movie, not necessarily the draft's file).
    public let url: URL
    /// Where the clip starts in `url` (the trim start), and how long it is, in millis.
    public let offsetMs: Int
    public let durationMs: Int

    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let images = CIContext(options: [.cacheIntermediates: false])
    private var lastFrame: CGImage?
    private var started = false

    public init(url: URL, offsetMs: Int, durationMs: Int) {
        self.url = url
        self.offsetMs = max(offsetMs, 0)
        self.durationMs = max(durationMs, 0)
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.forwardPlaybackEndTime = Self.time(self.offsetMs + self.durationMs)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
    }

    deinit { player.pause() }

    /// True from `play` until `pause` or the end of the clip (the player pauses itself there).
    public var isPlaying: Bool { started && player.rate != 0 }

    /// Starts playing from `millis` into the clip. From the end, it restarts at the beginning.
    public func play(fromMs millis: Int) {
        let start = PlaybackRules.startPosition(millis, durationMs: durationMs)
        player.seek(to: Self.time(offsetMs + start), toleranceBefore: .zero, toleranceAfter: .zero)
        lastFrame = nil
        started = true
        player.play()
    }

    /// Stops and returns where playback stopped.
    @discardableResult
    public func pause() -> Int {
        player.pause()
        started = false
        return currentMs
    }

    /// Where the player is, in millis into the clip, clamped to it.
    public var currentMs: Int {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return 0 }
        return PlaybackRules.clipPosition(mediaMs: Int((seconds * 1000).rounded()), offsetMs: offsetMs, durationMs: durationMs)
    }

    /// True once the player has reached the clip's end.
    public var isAtEnd: Bool { PlaybackRules.reachedEnd(currentMs, durationMs: durationMs) }

    /// The frame the player shows now, or the last one it showed when no new frame is ready.
    public func frame() -> CGImage? {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            let image = CIImage(cvPixelBuffer: buffer)
            lastFrame = images.createCGImage(image, from: image.extent) ?? lastFrame
        }
        return lastFrame
    }

    static func time(_ millis: Int) -> CMTime { CMTime(value: CMTimeValue(millis), timescale: 1000) }
}

/// Where playback starts, stops, and is, in clip time. Pure, so the rules are unit-tested apart
/// from AVFoundation.
public enum PlaybackRules {
    /// Within this many millis of the end, the clip counts as played through.
    public static let endToleranceMs = 30

    /// Play from `millis`, or from the beginning when the playhead is at (or past) the end.
    public static func startPosition(_ millis: Int, durationMs: Int) -> Int {
        reachedEnd(millis, durationMs: durationMs) ? 0 : min(max(millis, 0), durationMs)
    }

    /// A player time in the base movie mapped into the clip as trimmed.
    public static func clipPosition(mediaMs: Int, offsetMs: Int, durationMs: Int) -> Int {
        min(max(mediaMs - offsetMs, 0), durationMs)
    }

    public static func reachedEnd(_ millis: Int, durationMs: Int) -> Bool {
        millis >= durationMs - endToleranceMs
    }
}
