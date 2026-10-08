import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import UXReviewKit

extension EncodingTests {
    /// HS2-M03YP2 through real files: a video crop is simulated in the editor (frames drawn cut),
    /// recorded in edits.json next to the trim, shown cropped in the Submit Review list, and
    /// exported with the trim in one pass when submitting. The movie is 160 × 90, 2 s at 10 fps,
    /// in four colored quadrants (split at x = 80, y = 45) that change colors after 1 s.
    @Suite(.timeLimit(.minutes(2)))
    struct VideoCropTests {
        /// Quadrant colors: top left, top right, bottom left, bottom right.
        static let firstSecond = ["red", "green", "blue", "white"]
        static let secondSecond = ["white", "blue", "green", "red"]

        final class Fixture {
            let base: URL
            let store: ReviewDraftStore
            let draft: ReviewDraft

            init() async throws {
                base = try TestSupport.makeTempDirectory()
                store = ReviewDraftStore(root: base.appendingPathComponent("Drafts"))
                let movie = base.appendingPathComponent("source.mov")
                let duration = try await VideoCropTests.writeMovie(to: movie)
                draft = try store.add(DraftCapture(
                    fileURL: movie, kind: .video, pixelWidth: 160, pixelHeight: 90, durationMs: duration,
                    capturedAt: Date(timeIntervalSince1970: 0), context: CaptureContext()
                )).draft
            }

            deinit { try? FileManager.default.removeItem(at: base) }

            var movieURL: URL { draft.directory.appendingPathComponent("capture-1.mov") }
            func session() throws -> EditorSession { try EditorSession(store: store, directory: draft.directory) }
        }

        static func writeMovie(to url: URL) async throws -> Int {
            let writer = try VideoFileWriter(url: url, width: 160, height: 90, framesPerSecond: 10)
            let first = try #require(VideoFileWriter.pixelBuffer(from: quadrants(firstSecond), width: 160, height: 90))
            let second = try #require(VideoFileWriter.pixelBuffer(from: quadrants(secondSecond), width: 160, height: 90))
            for index in 0 ..< 20 {
                let time = CMTime(value: CMTimeValue(index * 60), timescale: 600)
                while !writer.append(index < 10 ? first : second, at: time) {
                    try await Task.sleep(for: .milliseconds(5))
                    if writer.framesDropped > 2000 { throw VideoWriterError.failed("encoder never became ready") }
                }
            }
            return try await writer.finish(at: CMTime(seconds: 2, preferredTimescale: 600))
        }

        static func rgb(_ name: String) -> (CGFloat, CGFloat, CGFloat) {
            switch name {
            case "red": (1, 0, 0)
            case "green": (0, 1, 0)
            case "blue": (0, 0, 1)
            default: (1, 1, 1)
            }
        }

        static func quadrants(_ colors: [String]) throws -> CGImage {
            let context = try #require(CGContext(
                data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            // CoreGraphics draws bottom-up: the top quadrants are at y 45…90.
            for (index, rect) in [
                CGRect(x: 0, y: 45, width: 80, height: 45), CGRect(x: 80, y: 45, width: 80, height: 45),
                CGRect(x: 0, y: 0, width: 80, height: 45), CGRect(x: 80, y: 0, width: 80, height: 45),
            ].enumerated() {
                let (red, green, blue) = rgb(colors[index])
                context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
                context.fill(rect)
            }
            return try #require(context.makeImage())
        }

        /// The color name at pixel (`x`, `y`) from the top left: each channel read as on or off.
        static func color(_ frame: CGImage?, _ x: Int, _ y: Int) throws -> String {
            let image = try #require(frame)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(
                data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let offset = (y * image.width + x) * 4
            switch (pixels[offset] > 128, pixels[offset + 1] > 128, pixels[offset + 2] > 128) {
            case (true, false, false): return "red"
            case (false, true, false): return "green"
            case (false, false, true): return "blue"
            case (true, true, true): return "white"
            default: return "rgb(\(pixels[offset]), \(pixels[offset + 1]), \(pixels[offset + 2]))"
            }
        }

        /// The colors of an 80 × 50 frame cut at (40, 20): one point inside each source quadrant.
        static func cropColors(_ image: CGImage?) throws -> [String] {
            try [(20, 10), (60, 10), (20, 40), (60, 40)].map { try color(image, $0.0, $0.1) }
        }

        static let crop = PixelRect(x: 40, y: 20, width: 80, height: 50)

        @Test func theCropIsSimulatedThenExportedWithTheTrimInOnePass() async throws {
            let fixture = try await Fixture()
            let originalBytes = try Data(contentsOf: fixture.movieURL)
            let session = try fixture.session()
            AnnotationEditorTests.draw(&session.editor, .rect, [CGPoint(x: 50, y: 30), CGPoint(x: 70, y: 40)]) // inside
            AnnotationEditorTests.draw(&session.editor, .insertion, [CGPoint(x: 150, y: 80)]) // outside the crop
            let drawn = session.editor.bundle.annotations.map(\.shape)

            // The Crop tool shows the whole frame; other tools the cut frame.
            session.editor.setTool(.crop)
            #expect(session.canvasImage()?.width == 160 && session.canvasImage()?.height == 90)
            AnnotationEditorTests.drag(&session.editor, [CGPoint(x: 40, y: 20), CGPoint(x: 120, y: 70)])
            #expect(session.editor.document.crops["m1"] == Self.crop)
            #expect(session.canvasItems().map(\.annotation.shape) == drawn)
            session.editor.setTool(.select)
            let frame = session.canvasImage()
            #expect(frame?.width == 80 && frame?.height == 50)
            #expect(try Self.cropColors(frame) == Self.firstSecond)
            // A frame the size of the original (as the player gives) is cut the same way.
            let whole = try Self.quadrants(Self.firstSecond)
            #expect(try Self.cropColors(session.cropped(whole, for: "m1")) == Self.firstSecond)
            #expect(session.canvasItems().map(\.annotation.id) == ["a1"])
            let trimmed = session.editor.trim(to: TimeRange(startMs: 1000, endMs: 2000))
            #expect(trimmed)
            #expect(try Self.cropColors(session.displayImage("m1", atMs: 0)) == Self.secondSecond)
            try session.save()

            // The movie is never rewritten; edits.json has the crop next to the trim.
            #expect(try Data(contentsOf: fixture.movieURL) == originalBytes)
            let edits = DraftEdits.load(from: fixture.draft.directory)
            #expect(edits.crops == ["capture-1.mov": Self.crop])
            #expect(edits.trims == ["capture-1.mov": TimeRange(startMs: 1000, endMs: 2000)])
            let disk = try fixture.store.load(fixture.draft.directory).bundle
            #expect(disk.media[0].pixelWidth == 160 && disk.annotations.map(\.shape) == drawn)

            // The Submit Review list: cropped size, a cropped thumbnail at the trim start, the
            // outsider left out.
            let preview = SubmissionPreview(disk, edits: edits)
            let filed = try #require(preview.media["m1"])
            #expect(filed.pixelWidth == 80 && filed.pixelHeight == 50 && filed.durationMs == 1000)
            #expect(filed.crop == Self.crop && filed.annotationCount == 1)
            #expect(filed.leftOutNote == "1 annotation outside the crop or trim will be left out")
            let thumbnail = MediaThumbnail.make(fixture.movieURL, kind: .video, crop: Self.crop, atMs: 1000)
            #expect(thumbnail?.width == 80 && thumbnail?.height == 50)
            #expect(try Self.cropColors(thumbnail) == Self.secondSecond)

            // Submitting exports the trimmed and cropped movie in one pass.
            let staged = try SubmissionStaging.prepare(fixture.store.load(fixture.draft.directory))
            defer { staged.cleanUp() }
            let movie = staged.mediaDirectory.appendingPathComponent("capture-1.mov")
            let info = try await VideoFileWriter.inspect(movie)
            #expect(info.width == 80 && info.height == 50)
            #expect(abs(info.durationMs - 1000) <= 110, "within a frame: \(info.durationMs)")
            let frames = VideoFrames(url: movie)
            #expect(try Self.cropColors(frames.frame(atMs: 100)) == Self.secondSecond)
            #expect(try Self.cropColors(frames.frame(atMs: 900)) == Self.secondSecond)
            #expect(staged.bundle.media[0].pixelWidth == 80 && staged.bundle.media[0].pixelHeight == 50)
            #expect(staged.bundle.media[0].durationMs == 1000)
            #expect(staged.dropped == ["a2"] && staged.bundle.annotations.map(\.id) == ["a1"])
            // Crop-local 10…30 × 10…20 px of 80 × 50 (y within 1 unit: 30 / 90 isn't exact in 0…10000).
            guard case let .rect(box) = staged.bundle.annotations[0].shape else { Issue.record("not a rect"); return }
            #expect(box.x == 1250 && box.width == 2500 && abs(box.y - 2000) <= 1 && abs(box.height - 2000) <= 1)
            #expect(staged.bundle.validate().isEmpty)
            #expect(try Data(contentsOf: fixture.movieURL) == originalBytes)
        }

        /// With AI downscaling on (`HS2-PT8PM6`), the same single export crops first, then scales
        /// the crop down; the bundle's size is the movie's.
        @Test func aCropThenScaleIsStillOneExport() async throws {
            let fixture = try await Fixture()
            try DraftEdits(crops: ["capture-1.mov": Self.crop], trims: ["capture-1.mov": TimeRange(startMs: 1000, endMs: 2000)])
                .save(to: fixture.draft.directory)
            let target = MediaScaleTarget(rule: .longestEdge(40), audience: "AI")
            let preview = try #require(SubmissionPreview(
                fixture.store.load(fixture.draft.directory).bundle,
                edits:
                DraftEdits.load(from: fixture.draft.directory),
                scale: target
            ).media["m1"])
            let staged = try SubmissionStaging.prepare(fixture.store.load(fixture.draft.directory), scale: target)
            defer { staged.cleanUp() }
            let movie = staged.mediaDirectory.appendingPathComponent("capture-1.mov")
            let info = try await VideoFileWriter.inspect(movie)
            #expect(info.width == 40 && info.height % 2 == 0 && abs(info.height - 25) <= 1)
            #expect(staged.bundle.media[0].pixelWidth == info.width && staged.bundle.media[0].pixelHeight == info.height)
            #expect(staged.scaledFrom == ["m1": PixelSize(width: 80, height: 50)], "scaled from the crop's size")
            #expect(preview.pixelWidth == info.width && preview.sizeText == "40×\(info.height) cropped, scaled for AI")
            #expect(abs(info.durationMs - 1000) <= 110)
            let frame = VideoFrames(url: movie).frame(atMs: 300)
            #expect(
                try [(10, 5), (30, 5), (10, info.height - 5), (30, info.height - 5)].map { try Self.color(frame, $0.0, $0.1) }
                    == Self.secondSecond
            )
        }

        /// A crop alone exports the whole length; a crop record with odd sides (not made by the
        /// editor) renders at the even size below it.
        @Test func aCropAloneKeepsTheWholeMovie() async throws {
            let fixture = try await Fixture()
            let target = fixture.base.appendingPathComponent("cropped.mov")
            try VideoTrim.export(fixture.movieURL, range: nil, crop: PixelRect(x: 80, y: 0, width: 81, height: 45), to: target)
            let info = try await VideoFileWriter.inspect(target)
            #expect(info.width == 80 && info.height == 44)
            #expect(abs(info.durationMs - 2000) <= 110)
            let frames = VideoFrames(url: target)
            #expect(try Self.color(frames.frame(atMs: 200), 40, 20) == "green")
            #expect(try Self.color(frames.frame(atMs: 1500), 40, 20) == "blue")

            // Restore Original in a later session removes both the crop and the trim.
            let session = try fixture.session()
            session.editor.setTool(.crop)
            AnnotationEditorTests.drag(&session.editor, [CGPoint(x: 40, y: 20), CGPoint(x: 120, y: 70)])
            _ = session.editor.trim(to: TimeRange(startMs: 500, endMs: 1500))
            try session.save()
            let reopened = try fixture.session()
            #expect(reopened.editor.document.crops["m1"] == Self.crop && reopened.editor.currentFrame?.width == 80)
            let restored = reopened.editor.restoreOriginal()
            #expect(restored)
            try reopened.save()
            #expect(DraftEdits.load(from: fixture.draft.directory).isEmpty)
            #expect(reopened.displayImage("m1")?.width == 160)
        }
    }
}
