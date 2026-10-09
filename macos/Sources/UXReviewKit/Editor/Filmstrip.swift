import AVFoundation
import CoreGraphics
import Foundation

/// The video timeline's filmstrip (`HS2-VMKTHQ`, docs/06 §6.10): small frames across the clip, as
/// in QuickTime Player, so the timeline shows where things happen.
public enum Filmstrip {
    /// How many frames fit a track `width` points wide when each is `height` points tall and the
    /// movie is `aspect` (width / height): at least 1, at most 40.
    public static func count(width: Double, height: Double, aspect: Double) -> Int {
        guard width > 0, height > 0, aspect > 0, aspect.isFinite else { return 1 }
        return min(max(Int((width / (height * aspect)).rounded(.up)), 1), 40)
    }

    /// `count` frame times (ms of the clip as trimmed), each in the middle of its slot.
    public static func times(durationMs: Int, count: Int) -> [Int] {
        guard durationMs > 0, count > 0 else { return [] }
        return (0 ..< count).map { Int(((Double($0) + 0.5) * Double(durationMs) / Double(count)).rounded()) }
    }

    /// The frames at `times` (ms of the clip), read from the movie at `url` offset by the trim's
    /// start, each at most `maxHeight` pixels tall. Blocks while it reads: call it off the main
    /// thread. A time without a frame gives nil there.
    public static func frames(url: URL, offsetMs: Int, times: [Int], maxHeight: Int) -> [CGImage?] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxHeight * 4, height: maxHeight)
        // A frame near each time is enough here, and much faster than the exact one.
        let tolerance = CMTime(value: 100, timescale: 1000)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return times.map { generator.blockingImage(at: CMTime(value: CMTimeValue(max($0 + offsetMs, 0)), timescale: 1000)) }
    }
}
