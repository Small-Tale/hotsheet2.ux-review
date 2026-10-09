import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// HS2-VMKTHQ: the video timeline's filmstrip.
extension EncodingTests {
    @Suite(.timeLimit(.minutes(1)))
    struct FilmstripTests {
        @Test func countsAndTimesFillTheTrack() {
            // A 16:10 movie, 44 pt tall frames: 70.4 pt each, so 1000 pt needs 15.
            #expect(Filmstrip.count(width: 1000, height: 44, aspect: 1.6) == 15)
            #expect(Filmstrip.count(width: 10, height: 44, aspect: 1.6) == 1)
            #expect(Filmstrip.count(width: 100_000, height: 44, aspect: 1.6) == 40)
            #expect(Filmstrip.count(width: 0, height: 44, aspect: 1.6) == 1)
            #expect(Filmstrip.count(width: 500, height: 44, aspect: .nan) == 1)
            #expect(Filmstrip.times(durationMs: 2000, count: 4) == [250, 750, 1250, 1750])
            #expect(Filmstrip.times(durationMs: 0, count: 4).isEmpty)
            #expect(Filmstrip.times(durationMs: 1000, count: 0).isEmpty)
        }

        /// Red for the first second, blue for the second: each frame comes from its own time,
        /// shifted by the trim's start, no taller than asked.
        @Test func framesComeFromTheirTimesInTheTrimmedClip() async throws {
            let base = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let movie = base.appendingPathComponent("clip.mov")
            _ = try await VideoTrimSessionTests.Fixture.writeMovie(to: movie)
            let frames = Filmstrip.frames(url: movie, offsetMs: 0, times: [250, 750, 1250, 1750], maxHeight: 45)
            #expect(frames.map { $0.map(Self.color) } == ["red", "red", "blue", "blue"])
            #expect(frames.allSatisfy { ($0?.height ?? 0) <= 45 && ($0?.height ?? 0) > 0 })
            // Trimmed to start at 0.5 s: clip times 250 and 750 are movie times 750 and 1250.
            let trimmed = Filmstrip.frames(url: movie, offsetMs: 500, times: [250, 750], maxHeight: 45)
            #expect(trimmed.map { $0.map(Self.color) } == ["red", "blue"])
            #expect(Filmstrip.frames(url: base.appendingPathComponent("gone.mov"), offsetMs: 0, times: [0], maxHeight: 45) == [nil])
        }

        static func color(_ image: CGImage) -> String {
            let rep = NSBitmapImageRep(cgImage: image)
            guard let pixel = rep.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB) else { return "none" }
            return pixel.redComponent > pixel.blueComponent ? "red" : "blue"
        }
    }
}
