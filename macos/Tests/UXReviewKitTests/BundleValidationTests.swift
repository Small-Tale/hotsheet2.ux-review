import Foundation
import Testing
@testable import UXReviewKit

struct BundleValidationTests {
    private let rect = Shape.rect(NormRect(x: 0, y: 0, width: 10, height: 10))

    @Test func emptyMediaIsRejected() {
        #expect(TestSupport.bundle(media: []).validate() == [.noMedia])
    }

    @Test func unsupportedSchemaIsRejected() {
        var bundle = TestSupport.bundle()
        bundle.schema = "uxreview/bundle/v0"
        #expect(bundle.validate() == [.unsupportedSchema("uxreview/bundle/v0")])
    }

    @Test func duplicateMediaIdsFilenamesAndBadSizes() {
        var bad = TestSupport.image("m1", filename: "a.png")
        bad.pixelWidth = 0
        let bundle = TestSupport.bundle(media: [TestSupport.image("m1", filename: "a.png"), bad])
        #expect(bundle.validate() == [.duplicateMediaId("m1"), .duplicateFilename("a.png"), .invalidMediaSize(mediaId: "m1")])
    }

    @Test func duplicateAnnotationIdsAndUnknownMedia() {
        let bundle = TestSupport.bundle(annotations: [
            Annotation(id: "a", mediaId: "m1", shape: rect, note: ""),
            Annotation(id: "a", mediaId: "nope", shape: rect, note: ""),
        ])
        #expect(bundle.validate() == [.duplicateAnnotationId("a"), .unknownMedia(annotationId: "a", mediaId: "nope")])
    }

    @Test(arguments: [
        Shape.rect(NormRect(x: 9995, y: 0, width: 10, height: 10)),
        Shape.rect(NormRect(x: 0, y: 0, width: 0, height: 10)),
        Shape.strike(NormRect(x: -1, y: 0, width: 5, height: 5)),
        Shape.insertion(NormPoint(x: 10001, y: 0)),
    ])
    func outOfBoundsShapesAreRejected(shape: Shape) {
        let bundle = TestSupport.bundle(annotations: [Annotation(id: "a", mediaId: "m1", shape: shape, note: "")])
        #expect(bundle.validate() == [.shapeOutOfBounds(annotationId: "a")])
    }

    @Test func pathShapesNeedEnoughInBoundsPoints() {
        let bundle = TestSupport.bundle(annotations: [
            Annotation(id: "arrow", mediaId: "m1", shape: .arrow(points: [NormPoint(x: 1, y: 1)]), note: ""),
            Annotation(
                id: "free",
                mediaId: "m1",
                shape: .freehand(points: [NormPoint(x: 1, y: 1), NormPoint(x: 2, y: 20000)], closed: false),
                note: ""
            ),
            Annotation(id: "ok", mediaId: "m1", shape: .arrow(points: [NormPoint(x: 1, y: 1), NormPoint(x: 2, y: 2)]), note: ""),
        ])
        #expect(bundle.validate() == [
            .tooFewPoints(annotationId: "arrow", minimum: 2),
            .tooFewPoints(annotationId: "free", minimum: 3),
            .shapeOutOfBounds(annotationId: "free"),
        ])
    }

    @Test func timeRangesOnlyOnVideoAndWithinDuration() {
        let bundle = TestSupport.bundle(media: [TestSupport.image(), TestSupport.video(durationMs: 5000)], annotations: [
            Annotation(id: "img", mediaId: "m1", shape: rect, note: "", timeRange: TimeRange(startMs: 0, endMs: 0)),
            Annotation(id: "rev", mediaId: "v1", shape: rect, note: "", timeRange: TimeRange(startMs: 300, endMs: 200)),
            Annotation(id: "long", mediaId: "v1", shape: rect, note: "", timeRange: TimeRange(startMs: 0, endMs: 5001)),
            Annotation(id: "instant", mediaId: "v1", shape: rect, note: "", timeRange: TimeRange(startMs: 5000, endMs: 5000)),
            Annotation(id: "whole", mediaId: "v1", shape: rect, note: ""),
        ])
        #expect(bundle.validate() == [
            .timeRangeOnImage(annotationId: "img"),
            .invalidTimeRange(annotationId: "rev"),
            .timeRangeBeyondDuration(annotationId: "long"),
        ])
    }
}
