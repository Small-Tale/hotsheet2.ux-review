import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// The Submit Review window's "as filed" view (HS2-64P9DT, docs/07 §7.2): sizes, lengths, and
/// annotation counts after crops and trims, the annotations they leave out, and thumbnails of
/// the cropped part or the trim's first frame.
struct SubmissionPreviewTests {
    static let image = MediaItem(
        id: "m1", filename: "capture-1.png", kind: .image, pixelWidth: 1600, pixelHeight: 1000, capturedAt: Date(timeIntervalSince1970: 0)
    )
    static let plain = MediaItem(
        id: "m2", filename: "capture-2.png", kind: .image, pixelWidth: 800, pixelHeight: 600, capturedAt: Date(timeIntervalSince1970: 0)
    )
    static let movie = TestSupport.video("m3", filename: "capture-3.mov", durationMs: 4000)

    static func rect(_ x: Int, _ y: Int, _ mediaId: String, _ id: String, range: TimeRange? = nil) -> Annotation {
        Annotation(id: id, mediaId: mediaId, shape: .rect(NormRect(x: x, y: y, width: 1000, height: 1000)), note: "", timeRange: range)
    }

    static var bundle: ReviewBundle {
        ReviewBundle(
            id: "r", title: "t", createdAt: Date(timeIntervalSince1970: 0), media: [image, plain, movie],
            annotations: [
                rect(500, 500, "m1", "a1"), // top left: outside a lower-right crop
                rect(7000, 7000, "m1", "a2"),
                rect(4000, 4000, "m2", "a3"),
                rect(4000, 4000, "m3", "a4", range: TimeRange(startMs: 500, endMs: 900)),
                rect(4000, 4000, "m3", "a5", range: TimeRange(startMs: 3000, endMs: 3500)), // after the trim
                rect(4000, 4000, "m3", "a6"), // whole clip
            ]
        )
    }

    @Test func noEditsShowsTheDraftAsIs() {
        let preview = SubmissionPreview(Self.bundle, edits: DraftEdits())
        #expect(preview.media["m1"] == .init(
            pixelWidth: 1600, pixelHeight: 1000, durationMs: nil, crop: nil, trim: nil, annotationCount: 2, leftOutCount: 0
        ))
        #expect(preview.media["m3"]?.durationMs == 4000 && preview.media["m3"]?.annotationCount == 3)
        #expect(preview.annotationCount == 6 && preview.leftOutCount == 0)
        #expect(preview.media.values.allSatisfy { $0.leftOutNote == nil })
    }

    @Test func cropsAndTrimsShowAsFiled() {
        let crop = PixelRect(x: 800, y: 500, width: 800, height: 500)
        let trim = TimeRange(startMs: 0, endMs: 2000)
        let preview = SubmissionPreview(Self.bundle, edits: DraftEdits(
            crops: ["capture-1.png": crop], trims: ["capture-3.mov": trim]
        ))
        let image = preview.media["m1"]
        #expect(image?.pixelWidth == 800 && image?.pixelHeight == 500 && image?.crop == crop)
        #expect(image?.annotationCount == 1 && image?.leftOutCount == 1)
        #expect(image?.leftOutNote == "1 annotation outside the crop will be left out")
        let movie = preview.media["m3"]
        #expect(movie?.durationMs == 2000 && movie?.trim == trim && movie?.annotationCount == 2)
        #expect(movie?.leftOutNote == "1 annotation outside the trim will be left out")
        #expect(preview.media["m2"]?.crop == nil && preview.media["m2"]?.annotationCount == 1)
        #expect(preview.annotationCount == 4 && preview.leftOutCount == 2)
    }

    /// Records for unknown files, a crop that doesn't fit, and a "crop" of the whole image are
    /// ignored, as when submitting (`DraftEdits.byMediaId`).
    @Test func editsThatDontApplyAreIgnored() {
        let preview = SubmissionPreview(Self.bundle, edits: DraftEdits(
            crops: [
                "gone.png": PixelRect(x: 0, y: 0, width: 10, height: 10),
                "capture-1.png": PixelRect(x: 0, y: 0, width: 1600, height: 1000),
                "capture-2.png": PixelRect(x: 700, y: 0, width: 200, height: 10),
            ],
            trims: ["capture-3.mov": TimeRange(startMs: 0, endMs: 9000)]
        ))
        #expect(preview == SubmissionPreview(Self.bundle, edits: DraftEdits()))
    }

    /// Every annotation outside: the counts say so in the plural; an empty review previews empty.
    @Test func pluralAndEmpty() {
        var bundle = Self.bundle
        bundle.annotations.append(Self.rect(100, 6000, "m1", "a7"))
        let preview = SubmissionPreview(
            bundle,
            edits: DraftEdits(crops: ["capture-1.png": PixelRect(x: 800, y: 0, width: 800, height: 400)])
        )
        #expect(preview.media["m1"]?.annotationCount == 0)
        #expect(preview.media["m1"]?.leftOutNote == "3 annotations outside the crop will be left out")
        let empty = SubmissionPreview(ReviewBundle(id: "r", title: "t", createdAt: Date(), media: [], annotations: []), edits: DraftEdits())
        #expect(empty.media.isEmpty && empty.annotationCount == 0 && empty.leftOutCount == 0)
    }

    @Test func imageThumbnailsShowOnlyTheCrop() throws {
        let base = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        // Left half red, right half blue.
        let context = try #require(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        let url = base.appendingPathComponent("capture-1.png")
        try ImageFiles.writePNG(try #require(context.makeImage()), to: url)

        let whole = try #require(MediaThumbnail.make(url, kind: .image, maxPixels: 100))
        #expect(whole.width == 100 && whole.height == 50)
        let right = MediaThumbnail.make(url, kind: .image, crop: PixelRect(x: 200, y: 0, width: 200, height: 100), maxPixels: 100)
        #expect(right?.width == 100 && right?.height == 50)
        #expect(try EncodingTests.VideoTrimSessionTests.color(right) == "blue")
        let left = MediaThumbnail.make(url, kind: .image, crop: PixelRect(x: 0, y: 50, width: 60, height: 40), maxPixels: 100)
        #expect(left?.width == 60 && left?.height == 40) // never scaled up
        #expect(try EncodingTests.VideoTrimSessionTests.color(left) == "red")
        #expect(MediaThumbnail.make(url, kind: .image, crop: PixelRect(x: 500, y: 0, width: 10, height: 10)) == nil)
    }
}

extension EncodingTests {
    /// A movie's thumbnail is its frame at the trim start (red for the first second, blue after).
    @Suite(.timeLimit(.minutes(1)))
    struct SubmissionThumbnailTests {
        @Test func movieThumbnailsShowTheTrimStart() async throws {
            let base = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let url = base.appendingPathComponent("clip.mov")
            _ = try await VideoTrimSessionTests.Fixture.writeMovie(to: url)
            #expect(try VideoTrimSessionTests.color(MediaThumbnail.make(url, kind: .video)) == "red")
            #expect(try VideoTrimSessionTests.color(MediaThumbnail.make(url, kind: .video, atMs: 1500)) == "blue")
        }
    }
}

/// HS2-WE6ST8: a capture note as the Submit Review lists show it.
struct CaptureNotePreviewTests {
    @Test func captureNotesPreviewAsOneTrimmedLine() {
        #expect(SubmissionPreview.notePreview(nil) == nil)
        #expect(SubmissionPreview.notePreview(" \n\t ") == nil)
        #expect(SubmissionPreview.notePreview("  Feels cramped.\n\nGive the   form room. ") == "Feels cramped. Give the form room.")
        let long = String(repeating: "word ", count: 60)
        let preview = SubmissionPreview.notePreview(long, limit: 40)
        #expect(preview?.count == 40)
        #expect(preview?.hasSuffix("…") == true)
        #expect(SubmissionPreview.notePreview("exactly ten", limit: 11) == "exactly ten")
    }
}
