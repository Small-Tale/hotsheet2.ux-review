import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

extension EncodingTests {
    /// HS2-ZMDH5D: AI downscaling (`HS2-PT8PM6`) of a movie whose track carries a non-identity
    /// preferred transform, as an iPhone portrait clip does. The track is stored 160 × 90 in four
    /// colored quadrants; the transform turns it as displayed. The filed movie must be the
    /// displayed picture (upright, its sides swapped for a quarter turn), scaled, with an identity
    /// transform, and the bundle must record the size as filed.
    @Suite(.timeLimit(.minutes(2)))
    struct RotatedMovieScalingTests {
        /// Stored quadrant colors: top left, top right, bottom left, bottom right.
        static let stored = VideoCropTests.firstSecond // red, green, blue, white

        /// Quarter turn clockwise, the transform an iPhone writes for a portrait clip: stored
        /// (x, y) → displayed (90 − y, x), so the displayed frame is 90 × 160 at the origin.
        static let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 90, ty: 0)
        /// Half turn without a translation: the displayed frame lies at (−160, −90), which
        /// `renderTransform` has to move back to the origin.
        static let upsideDown = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)

        /// Writes a 1 s, 10 fps movie of the stored quadrants with `transform` on its track.
        static func writeRotatedMovie(to url: URL, transform: CGAffineTransform) async throws {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
            ])
            input.transform = transform
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            #expect(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            let frame = try #require(VideoFileWriter.pixelBuffer(from: VideoCropTests.quadrants(stored), width: 160, height: 90))
            for index in 0 ..< 10 {
                var waits = 0
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                    waits += 1
                    if waits > 2000 { throw VideoWriterError.failed("encoder never became ready") }
                }
                #expect(adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 10)))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
            await writer.finishWriting()
            guard writer.status == .completed else { throw VideoWriterError.failed("\(String(describing: writer.error))") }
        }

        /// The track's stored size and transform.
        static func geometry(_ url: URL) async throws -> (size: CGSize, transform: CGAffineTransform) {
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
            let track = try #require(tracks.first)
            let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
            return (size, transform)
        }

        /// Colors at one point inside each quadrant of a displayed `width` × `height` frame:
        /// top left, top right, bottom left, bottom right.
        static func quadrantColors(_ frame: CGImage?, width: Int, height: Int) throws -> [String] {
            let (left, right, top, bottom) = (width / 4, width * 3 / 4, height / 4, height * 3 / 4)
            return try [(left, top), (right, top), (left, bottom), (right, bottom)].map { try VideoCropTests.color(frame, $0.0, $0.1) }
        }

        /// A portrait iPhone-style clip imports at its displayed size and is filed upright and
        /// scaled: 90 × 160 displayed → longest edge 80 → even sides, the colors where the
        /// displayed source shows them.
        @Test func aPortraitClipIsFiledUprightAndScaled() async throws {
            let base = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let source = base.appendingPathComponent("IMG_0001.MOV")
            try await Self.writeRotatedMovie(to: source, transform: Self.portrait)
            let stored = try await Self.geometry(source)
            #expect(stored.size == CGSize(width: 160, height: 90))

            // The displayed source, as the editor shows it: a quarter turn clockwise.
            let displayed = try Self.quadrantColors(VideoFrames(url: source).frame(atMs: 500), width: 90, height: 160)
            #expect(displayed == ["blue", "red", "white", "green"])

            let store = ReviewDraftStore(root: base.appendingPathComponent("Drafts"))
            let (draft, media) = try await MediaImporter.importFiles([source], into: store)
            #expect(media[0].pixelWidth == 90 && media[0].pixelHeight == 160, "imported at the displayed size")

            let target = MediaScaleTarget(rule: .longestEdge(80), audience: "AI")
            let expected = target.videoSize(for: PixelSize(width: 90, height: 160))
            #expect(expected.height == 80 && expected.width % 2 == 0 && abs(expected.width - 45) <= 1)
            let preview = try #require(SubmissionPreview(draft.bundle, edits: DraftEdits(), scale: target).media[media[0].id])
            #expect(preview.pixelWidth == expected.width && preview.pixelHeight == expected.height)
            #expect(preview.sizeText == "\(expected.width)×80 scaled for AI")

            let staged = try SubmissionStaging.prepare(store.load(draft.directory), scale: target)
            defer { staged.cleanUp() }
            let movie = staged.mediaDirectory.appendingPathComponent(media[0].filename)
            let filed = try await Self.geometry(movie)
            #expect(filed.size == CGSize(width: expected.width, height: expected.height), "rendered upright: portrait sides")
            #expect(filed.transform.isIdentity, "the rotation is baked into the pixels")
            #expect(staged.bundle.media[0].pixelWidth == expected.width && staged.bundle.media[0].pixelHeight == 80)
            #expect(staged.scaledFrom == [media[0].id: PixelSize(width: 90, height: 160)])
            let info = try await VideoFileWriter.inspect(movie)
            #expect(abs(info.durationMs - 1000) <= 110)
            let frame = VideoFrames(url: movie).frame(atMs: 500)
            #expect(try Self.quadrantColors(frame, width: expected.width, height: 80) == displayed)
        }

        /// A half turn whose displayed frame lies off the origin, through `VideoTrim.export`
        /// directly: the same size as stored, upside down, and with a crop of the displayed
        /// picture (its top half) the crop is of what is shown, not of the stored pixels.
        @Test func anUpsideDownClipIsMovedBackOntoTheFrame() async throws {
            let base = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let source = base.appendingPathComponent("flipped.mov")
            try await Self.writeRotatedMovie(to: source, transform: Self.upsideDown)
            let displayed = try Self.quadrantColors(VideoFrames(url: source).frame(atMs: 500), width: 160, height: 90)
            #expect(displayed == ["white", "blue", "green", "red"])

            let scaled = base.appendingPathComponent("scaled.mov")
            try VideoTrim.export(source, range: nil, size: PixelSize(width: 80, height: 44), to: scaled)
            let geometry = try await Self.geometry(scaled)
            #expect(geometry.size == CGSize(width: 80, height: 44) && geometry.transform.isIdentity)
            #expect(try Self.quadrantColors(VideoFrames(url: scaled).frame(atMs: 500), width: 80, height: 44) == displayed)

            // The displayed top half (white | blue), scaled to 80 × 22 → 80 × 22.
            let cropped = base.appendingPathComponent("cropped.mov")
            try VideoTrim.export(
                source, range: nil, crop: PixelRect(x: 0, y: 0, width: 160, height: 44),
                size: PixelSize(width: 80, height: 22), to: cropped
            )
            let croppedGeometry = try await Self.geometry(cropped)
            #expect(croppedGeometry.size == CGSize(width: 80, height: 22))
            let half = VideoFrames(url: cropped).frame(atMs: 500)
            #expect(try [VideoCropTests.color(half, 20, 11), VideoCropTests.color(half, 60, 11)] == ["white", "blue"])
        }

        /// `renderTransform` maps the displayed corners of a rotated track onto the output frame.
        @Test func theRenderTransformPutsTheDisplayedFrameAtTheOrigin() {
            for transform in [Self.portrait, Self.upsideDown] {
                let display = CGRect(x: 0, y: 0, width: 160, height: 90).applying(transform)
                let size = PixelSize(width: Int(display.width) / 2, height: Int(display.height) / 2)
                let render = VideoTrim.renderTransform(preferred: transform, display: display, to: size)
                let mapped = CGRect(x: 0, y: 0, width: 160, height: 90).applying(render)
                #expect(abs(mapped.minX) < 0.001 && abs(mapped.minY) < 0.001)
                #expect(abs(mapped.width - CGFloat(size.width)) < 0.001 && abs(mapped.height - CGFloat(size.height)) < 0.001)
            }
        }
    }
}
