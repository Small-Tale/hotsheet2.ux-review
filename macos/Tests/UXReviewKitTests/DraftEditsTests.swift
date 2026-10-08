import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// Crops and trims kept as edits until submitting (HS2-71SSJG): the edits file, the exact maps
/// into and out of a crop or trim, what counts as outside, clipping for submission, and a
/// cropped draft filed through `DraftSubmitter`. Spec: docs/06 §6.6, §6.10; docs/07 §7.5.
struct DraftEditsTests {
    static let size = PixelRect(x: 0, y: 0, width: 400, height: 200)
    static let crop = PixelRect(x: 100, y: 50, width: 200, height: 100)

    // MARK: Exact maps

    @Test func pointsMapIntoACropAndBackExactlyOrWithinOneUnit() {
        #expect(EditProjection.point(NormPoint(x: 2500, y: 2500), into: Self.crop, of: Self.size) == NormPoint(x: 0, y: 0))
        #expect(EditProjection.point(NormPoint(x: 7500, y: 7500), into: Self.crop, of: Self.size) == NormPoint(x: 10000, y: 10000))
        // Outside the crop: beyond 0…10000, never clamped.
        #expect(EditProjection.point(NormPoint(x: 0, y: 10000), into: Self.crop, of: Self.size) == NormPoint(x: -5000, y: 15000))
        let odd = PixelRect(x: 37, y: 11, width: 123, height: 77)
        for x in stride(from: 0, through: 10000, by: 371) {
            for y in stride(from: 0, through: 10000, by: 433) {
                let point = NormPoint(x: x, y: y)
                let back = EditProjection.point(EditProjection.point(point, into: odd, of: Self.size), outOf: odd, to: Self.size)
                #expect(abs(back.x - x) <= 1 && abs(back.y - y) <= 1, "\(point) → \(back)")
            }
        }
    }

    @Test func rangesShiftIntoATrimAndBackExactly() {
        let trim = TimeRange(startMs: 1000, endMs: 3000)
        let range = TimeRange(startMs: 500, endMs: 1500)
        #expect(EditProjection.range(range, into: trim) == TimeRange(startMs: -500, endMs: 500))
        #expect(EditProjection.range(EditProjection.range(range, into: trim), outOf: trim) == range)
    }

    @Test func outsideRules() {
        // Boxes need real overlap; points and paths may touch the edge.
        #expect(EditProjection.isOutside(.rect(NormRect(x: 10000, y: 0, width: 500, height: 500))))
        #expect(EditProjection.isOutside(.rect(NormRect(x: -500, y: 0, width: 500, height: 500))))
        #expect(!EditProjection.isOutside(.strike(NormRect(x: -500, y: 0, width: 501, height: 500))))
        #expect(!EditProjection.isOutside(.insertion(NormPoint(x: 10000, y: 10000))))
        #expect(EditProjection.isOutside(.insertion(NormPoint(x: 10001, y: 5000))))
        #expect(EditProjection.isOutside(.freehand(points: [NormPoint(x: -10, y: -10), NormPoint(x: -1, y: -500)], closed: false)))
        #expect(!EditProjection.isOutside(.arrow(points: [NormPoint(x: -3000, y: 5000), NormPoint(x: 100, y: 5000)])))
        #expect(EditProjection.isOutside(TimeRange(startMs: -10, endMs: -1), durationMs: 1000))
        #expect(EditProjection.isOutside(TimeRange(startMs: 1001, endMs: 1200), durationMs: 1000))
        #expect(!EditProjection.isOutside(TimeRange(startMs: -10, endMs: 0), durationMs: 1000))
        #expect(!EditProjection.isOutside(TimeRange(startMs: 1000, endMs: 1000), durationMs: 1000))
    }

    @Test func clippingForSubmissionClampsAndLeavesOutsidersOut() throws {
        let bundle = TestSupport.bundle(
            media: [AnnotationEditorTests.media(), AnnotationEditorTests.media("v1", kind: .video)],
            annotations: [
                Annotation(id: "a1", mediaId: "m1", shape: .rect(NormRect(x: -2000, y: 1000, width: 4000, height: 2000)), note: ""),
                Annotation(id: "a2", mediaId: "m1", shape: .insertion(NormPoint(x: 12000, y: 5000)), note: ""),
                Annotation(
                    id: "a3",
                    mediaId: "m1",
                    shape: .arrow(points: [NormPoint(x: -500, y: 5000), NormPoint(x: 500, y: 5000)]),
                    note: ""
                ),
                Annotation(
                    id: "a4", mediaId: "v1", shape: .rect(NormRect(x: 0, y: 0, width: 100, height: 100)), note: "",
                    timeRange: TimeRange(startMs: -500, endMs: 500)
                ),
                Annotation(
                    id: "a5", mediaId: "v1", shape: .rect(NormRect(x: 0, y: 0, width: 100, height: 100)), note: "",
                    timeRange: TimeRange(startMs: 4100, endMs: 4500)
                ),
            ]
        )
        let (clipped, dropped) = EditProjection.clippedToMedia(bundle)
        #expect(dropped == ["a2", "a5"])
        #expect(clipped.annotations.map(\.id) == ["a1", "a3", "a4"])
        #expect(clipped.annotations[0].shape == .rect(NormRect(x: 0, y: 1000, width: 2000, height: 2000)))
        #expect(clipped.annotations[1].shape == .arrow(points: [NormPoint(x: 0, y: 5000), NormPoint(x: 500, y: 5000)]))
        #expect(clipped.annotations[2].timeRange == TimeRange(startMs: 0, endMs: 500))
        #expect(clipped.validate().isEmpty)
    }

    // MARK: The edits file

    @Test func editsFileRoundTripsAndIgnoresWhatDoesNotFit() throws {
        let directory = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(DraftEdits.load(from: directory).isEmpty)
        var edits = DraftEdits(crops: ["m1.png": Self.crop], trims: ["v1.png": TimeRange(startMs: 100, endMs: 900)])
        try edits.save(to: directory)
        #expect(DraftEdits.load(from: directory) == edits)
        edits = DraftEdits()
        try edits.save(to: directory)
        #expect(!FileManager.default.fileExists(atPath: DraftEdits.url(in: directory).path), "no edits, no file")
        try Data(#"{"version": 2, "crops": {}, "trims": {}}"#.utf8).write(to: DraftEdits.url(in: directory))
        #expect(DraftEdits.load(from: directory).isEmpty, "another version is ignored")
        try Data("{oops".utf8).write(to: DraftEdits.url(in: directory))
        #expect(DraftEdits.load(from: directory).isEmpty)

        let bundle = TestSupport.bundle(media: [
            AnnotationEditorTests.media(), // 1000 × 500 image
            AnnotationEditorTests.media("v1", kind: .video), // 4000 ms
        ])
        let fitting = DraftEdits(
            crops: ["m1.png": PixelRect(x: 900, y: 400, width: 100, height: 100), "v1.png": Self.crop, "gone.png": Self.crop],
            trims: ["v1.png": TimeRange(startMs: 0, endMs: 4000), "m1.png": TimeRange(startMs: 0, endMs: 10)]
        ).byMediaId(in: bundle)
        #expect(fitting.crops == ["m1": PixelRect(x: 900, y: 400, width: 100, height: 100)])
        #expect(fitting.trims.isEmpty, "a whole-length trim is no trim; images have none")
        let outside = DraftEdits(
            crops: ["m1.png": PixelRect(x: 950, y: 0, width: 100, height: 100)],
            trims: ["v1.png": TimeRange(startMs: 3000, endMs: 4100)]
        ).byMediaId(in: bundle)
        #expect(outside.crops.isEmpty && outside.trims.isEmpty)
    }

    // MARK: Filing

    /// A cropped draft files a cropped PNG and clipped annotations; the draft's own file was
    /// never changed, and the outsider is left out of the ticket only.
    @Test func submittingACroppedDraftFilesTheCropAndClippedAnnotations() throws {
        let fixture = try DraftSubmitterTests.Fixture()
        let shot = fixture.base.appendingPathComponent("shot.png")
        try ImageFiles.writePNG(#require(ImageFiles.testCard(width: 400, height: 200)), to: shot)
        let draft = try fixture.store.add(DraftCapture(
            fileURL: shot, kind: .image, pixelWidth: 400, pixelHeight: 200, capturedAt: Date(), context: CaptureContext()
        )).draft
        let frame = MediaFrame(width: 400, height: 200)
        try fixture.store.update(draft.directory) { bundle in
            bundle.annotations = [
                Annotation(id: "a1", mediaId: "m1", shape: .rect(frame.norm(CGRect(x: 150, y: 75, width: 50, height: 50))), note: "in"),
                Annotation(id: "a2", mediaId: "m1", shape: .insertion(frame.norm(CGPoint(x: 20, y: 20))), note: "out"),
            ]
        }
        try DraftEdits(crops: ["capture-1.png": Self.crop]).save(to: draft.directory)
        var seen: (size: (Int, Int), bundle: ReviewBundle)?
        fixture.client.inspectAttached = { files in
            let image = try #require(files.first { $0.lastPathComponent == "capture-1.png" })
            let json = try #require(files.first { $0.lastPathComponent == "review.json" })
            let size = try ImageFiles.pixelSize(of: image)
            seen = ((size.width, size.height), try ReviewBundle.makeDecoder().decode(ReviewBundle.self, from: Data(contentsOf: json)))
        }
        let result = try fixture.submitter().submit(draft.directory)
        #expect(result.annotationCount == 1)
        let attached = try #require(seen)
        #expect(attached.size == (200, 100))
        #expect(attached.bundle.media[0].pixelWidth == 200 && attached.bundle.media[0].pixelHeight == 100)
        #expect(attached.bundle.annotations.map(\.id) == ["a1"])
        #expect(attached.bundle.annotations[0].shape == .rect(NormRect(x: 2500, y: 2500, width: 2500, height: 5000)))
        #expect(attached.bundle.validate().isEmpty)
        #expect(fixture.client.created.first?.details.contains("out") == false)
    }
}
