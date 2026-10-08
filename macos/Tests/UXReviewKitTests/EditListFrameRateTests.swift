import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import UXReviewKit

extension EncodingTests {

    /// Frame times through a real track's edit list (`HS2-Z4YPV1`, docs/06 §6.10): movies edited
    /// with `AVMutableMovie` so their track has several edits, one starting inside a frame, or an
    /// edit played at half speed. `VideoTrim.sampleTimesMs` maps each sample to the time it shows
    /// on the movie timeline, and `VideoTrim.frameRate` still finds the source's 10 fps.
    @Suite(.timeLimit(.minutes(2)))
    struct EditListFrameRateTests {
        typealias Movies = VariableFrameRateMovieTests

        static func ms(_ millis: Double) -> CMTime { CMTime(value: CMTimeValue((millis * 0.6).rounded()), timescale: 600) }

        /// A 1 s constant 10 fps source (no recorded rate) and an edited movie built from it by
        /// `edit`, written as a reference movie next to it.
        static func editedMovie(in base: URL, _ edit: (AVMutableMovie, AVMovie) async throws -> Void) async throws -> URL {
            let source = base.appendingPathComponent("source.mov")
            try await Movies.writePlainMovie(to: source, startsMs: (0 ..< 10).map { Double($0) * 100 }, endMs: 1000)
            let movie = AVMutableMovie()
            movie.timescale = 600
            try await edit(movie, AVMovie(url: source))
            let url = base.appendingPathComponent("edited-\(UUID().uuidString).mov")
            try movie.writeHeader(to: url, fileType: .mov, options: .addMovieHeaderToDestination)
            return url
        }

        static func presentationTimes(_ url: URL) async throws -> (segments: Int, times: [Double]) {
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
            let track = try #require(tracks.first)
            let segments = try await track.load(.segments).filter { !$0.isEmpty }.count
            let mapped = await VideoTrim.sampleTimesMs(track)
            let times = try #require(mapped)
            return (segments, times.map { ($0 * 100).rounded() / 100 }.sorted())
        }

        @Test func severalEditsOneStartingInsideAFrame() async throws {
            let base = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            // 0–500 ms of the source, then 250–750 ms of it again (from inside its frame at 200).
            let url = try await Self.editedMovie(in: base) { movie, source in
                try movie.insertTimeRange(
                    CMTimeRange(start: Self.ms(0), duration: Self.ms(500)),
                    of: source,
                    at: Self.ms(0),
                    copySampleData: false
                )
                try movie.insertTimeRange(
                    CMTimeRange(start: Self.ms(250), duration: Self.ms(500)),
                    of: source,
                    at: Self.ms(500),
                    copySampleData: false
                )
            }
            let (segments, times) = try await Self.presentationTimes(url)
            #expect(segments == 2)
            #expect(
                times == [0, 100, 200, 300, 400, 550, 650, 750, 850, 950],
                "the second edit's frames show 300 ms later than in the source; samples outside the edits are left out"
            )
            // The 50 ms from the second edit's start (inside a frame) to its next frame is no
            // interval: with the edit start counted as a frame time, this read 20 fps.
            #expect(VideoTrim.frameRate(of: url) == 10)
        }

        @Test func anEditAtHalfSpeedStretchesItsFrames() async throws {
            let base = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            // The second half plays at half speed: 500–1000 ms of the source take 1 s.
            let url = try await Self.editedMovie(in: base) { movie, source in
                try movie.insertTimeRange(
                    CMTimeRange(start: Self.ms(0), duration: Self.ms(1000)),
                    of: source,
                    at: Self.ms(0),
                    copySampleData: false
                )
                movie.scale(CMTimeRange(start: Self.ms(500), duration: Self.ms(500)), toDuration: Self.ms(1000))
            }
            let (segments, times) = try await Self.presentationTimes(url)
            #expect(segments == 2)
            #expect(times == [0, 100, 200, 300, 400, 500, 700, 900, 1100, 1300], "frames 200 ms apart in the slowed edit")
            #expect(VideoTrim.frameRate(of: url) == 10, "the shortest intervals keep the source's rate")
        }
    }
}
