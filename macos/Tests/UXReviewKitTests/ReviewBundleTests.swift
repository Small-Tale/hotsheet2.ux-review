import Foundation
import Testing
@testable import UXReviewKit

struct ReviewBundleTests {
    @Test func exampleBundleDecodesAndIsValid() throws {
        let bundle = try TestSupport.exampleBundle()
        #expect(bundle.schema == ReviewBundle.currentSchema)
        #expect(bundle.media.map(\.kind) == [.image, .video])
        #expect(bundle.annotations.map(\.shape.kind) == ["rect", "arrow", "strike", "insertion", "freehand", "arrow"])
        #expect(bundle.validate().isEmpty)
    }

    @Test func roundTripsThroughJSONExactly() throws {
        let bundle = try TestSupport.exampleBundle()
        let data = try ReviewBundle.makeEncoder().encode(bundle)
        let decoded = try ReviewBundle.makeDecoder().decode(ReviewBundle.self, from: data)
        #expect(decoded == bundle)
    }

    @Test func encoderMatchesCommittedExampleByteForByteModuloWhitespace() throws {
        // Keeps spec/examples in the exact shape the Swift encoder writes (no stray fields).
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: TestSupport.exampleBundleURL)) as? NSDictionary
        let reencoded = try JSONSerialization.jsonObject(
            with: ReviewBundle.makeEncoder().encode(TestSupport.exampleBundle())
        ) as? NSDictionary
        #expect(original == reencoded)
    }

    @Test func schemaEnumsMatchTheModel() throws {
        // Full JSON Schema validation of the example runs in scripts/check.sh (ajv); this
        // guards the enum lists against drift without a schema library.
        let url = TestSupport.repoRoot.appendingPathComponent("spec/review-bundle.schema.json")
        let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let defs = try #require(schema["$defs"] as? [String: Any])
        let intents = try #require((defs["intent"] as? [String: Any])?["enum"] as? [String])
        #expect(intents == Intent.allCases.map(\.rawValue))
        let kinds = try #require(
            (defs["media"] as? [String: Any])
                .flatMap { ($0["properties"] as? [String: Any])?["kind"] as? [String: Any] }
        )
        #expect(kinds["enum"] as? [String] == ["image", "video"])
        let shapes = try #require((defs["shape"] as? [String: Any])?["oneOf"] as? [[String: Any]])
        var shapeTypes: [String] = []
        for variant in shapes {
            let type = (variant["properties"] as? [String: Any])?["type"] as? [String: Any]
            shapeTypes += (type?["enum"] as? [String]) ?? [type?["const"] as? String].compactMap { $0 }
        }
        #expect(Set(shapeTypes) == ["rect", "strike", "freehand", "arrow", "insertion"])
        #expect(
            schema["properties"].flatMap { ($0 as? [String: Any])?["schema"] as? [String: Any] }?["const"] as? String
                == ReviewBundle.currentSchema
        )
    }

    /// `hasAudio` (HS2-EZN3NG) is optional: bundles written before it decode as "no audio /
    /// unknown", `true` round-trips, and `false` is never written.
    @Test func hasAudioIsOptionalAndOnlyEverWrittenAsTrue() throws {
        let old = #"{"id":"m1","filename":"a.mov","kind":"video","pixelWidth":2,"pixelHeight":2,"durationMs":5,"#
            + #""capturedAt":"2026-10-07T00:00:00Z"}"#
        let decoded = try ReviewBundle.makeDecoder().decode(MediaItem.self, from: Data(old.utf8))
        #expect(decoded.hasAudio == nil)

        func keys(_ item: MediaItem) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: ReviewBundle.makeEncoder().encode(item)) as? [String: Any])
        }
        #expect(try keys(decoded)["hasAudio"] == nil)
        let silent = MediaItem(
            id: "m1",
            filename: "a.mov",
            kind: .video,
            pixelWidth: 2,
            pixelHeight: 2,
            capturedAt: Date(),
            hasAudio: false
        )
        #expect(silent.hasAudio == nil)
        #expect(try keys(silent)["hasAudio"] == nil)

        var narrated = decoded
        narrated.hasAudio = true
        #expect(try keys(narrated)["hasAudio"] as? Bool == true)
        let data = try ReviewBundle.makeEncoder().encode(narrated)
        #expect(try ReviewBundle.makeDecoder().decode(MediaItem.self, from: data) == narrated)
        #expect(try TestSupport.exampleBundle().media.map(\.hasAudio) == [nil, true])
    }

    @Test func freehandWithoutClosedDefaultsToClosed() throws {
        let json = #"{"type":"freehand","points":[{"x":1,"y":1},{"x":2,"y":2},{"x":3,"y":1}]}"#
        let shape = try JSONDecoder().decode(Shape.self, from: Data(json.utf8))
        #expect(shape == .freehand(points: [NormPoint(x: 1, y: 1), NormPoint(x: 2, y: 2), NormPoint(x: 3, y: 1)], closed: true))
    }

    @Test func unknownShapeTypeFailsToDecode() {
        let json = #"{"type":"hexagon"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Shape.self, from: Data(json.utf8)) }
    }

    @Test(arguments: [
        (Shape.rect(NormRect(x: 1, y: 2, width: 3, height: 4)), NormRect(x: 1, y: 2, width: 3, height: 4)),
        (Shape.strike(NormRect(x: 5, y: 6, width: 7, height: 8)), NormRect(x: 5, y: 6, width: 7, height: 8)),
        (Shape.arrow(points: [NormPoint(x: 900, y: 100), NormPoint(x: 100, y: 700)]), NormRect(x: 100, y: 100, width: 800, height: 600)),
        (
            Shape.freehand(points: [NormPoint(x: 10, y: 10), NormPoint(x: 30, y: 5), NormPoint(x: 20, y: 40)], closed: true),
            NormRect(x: 10, y: 5, width: 20, height: 35)
        ),
        // Degenerate shapes grow to a 1-unit box so the Hot Sheet projection stays valid.
        (Shape.insertion(NormPoint(x: 500, y: 500)), NormRect(x: 500, y: 500, width: 1, height: 1)),
        (Shape.insertion(NormPoint(x: 10000, y: 10000)), NormRect(x: 9999, y: 9999, width: 1, height: 1)),
        (Shape.arrow(points: [NormPoint(x: 0, y: 50), NormPoint(x: 400, y: 50)]), NormRect(x: 0, y: 50, width: 400, height: 1)),
        (Shape.arrow(points: []), NormRect(x: 0, y: 0, width: 1, height: 1)),
    ])
    func boundsProjection(shape: Shape, expected: NormRect) {
        #expect(shape.bounds == expected)
        #expect(shape.bounds.isValid)
    }

    @Test func defaultIntentsFollowShape() {
        #expect(Shape.rect(NormRect(x: 0, y: 0, width: 1, height: 1)).defaultIntent == .comment)
        #expect(Shape.freehand(points: [], closed: true).defaultIntent == .comment)
        #expect(Shape.arrow(points: []).defaultIntent == .move)
        #expect(Shape.insertion(NormPoint(x: 0, y: 0)).defaultIntent == .insert)
        #expect(Shape.strike(NormRect(x: 0, y: 0, width: 1, height: 1)).defaultIntent == .remove)
    }

    @Test func explicitIntentsOverrideTheDefault() {
        let shape = Shape.rect(NormRect(x: 0, y: 0, width: 1, height: 1))
        #expect(Annotation(id: "a", mediaId: "m", shape: shape, note: "").effectiveIntents == [.comment])
        #expect(Annotation(id: "a", mediaId: "m", shape: shape, intents: [.remove, .bug], note: "").effectiveIntents == [.remove, .bug])
    }
}
