import Foundation
import Testing
@testable import UXReviewKit

/// UX Review annotations as Hot Sheet 2's native shapes and intents (docs/03 §3.4, `HS2-CKPCD5`).
struct HotSheetProjectionTests {
    private func project(_ shape: Shape, intents: [Intent] = [], note: String = "n") -> HotSheetMediaAnnotation {
        TicketComposer.hotSheetAnnotation(Annotation(id: "a", mediaId: "m", shape: shape, intents: intents, note: note), number: 3)
    }

    private let start = NormPoint(x: 100, y: 900)
    private let bend = NormPoint(x: 700, y: 300)
    private let finish = NormPoint(x: 400, y: 1000)

    @Test func eachShapeMapsOntoHotSheetsShape() {
        let box = NormRect(x: 10, y: 20, width: 30, height: 40)
        #expect(project(.rect(box)).shape == nil)
        #expect(project(.strike(box)).shape == .strike)
        #expect(project(.insertion(start)).shape == .insertion(start))
        #expect(project(.freehand(points: [start, bend, finish], closed: true)).shape == .freehand(
            points: [start, bend, finish],
            closed: true
        ))
        #expect(project(.freehand(points: [start, bend, finish], closed: false)).shape == .freehand(
            points: [start, bend, finish],
            closed: false
        ))
    }

    @Test func arrowsKeepTheirDirectionAndOtherHeadsBecomeLines() {
        // Hot Sheet's arrow has one head, at its last point.
        #expect(project(.arrow(points: [start, bend, finish])).shape == .arrow(points: [start, bend, finish]))
        #expect(project(.arrow(points: [start, bend], heads: ArrowHeads(start: .none, end: .open))).shape == .arrow(points: [start, bend]))
        #expect(project(.arrow(points: [start, bend, finish], heads: ArrowHeads(start: .closed, end: .none))).shape == .arrow(points: [
            finish,
            bend,
            start,
        ]))
        // Spans, bars, circles, and bare lines: an open line; two points gain their midpoint.
        let mid = NormPoint(x: 400, y: 600)
        for heads in [
            ArrowHeads(start: .closed, end: .closed), ArrowHeads(start: .flat, end: .flat),
            ArrowHeads(start: .none, end: .closedCircle), ArrowHeads(start: .none, end: .none),
        ] {
            #expect(project(.arrow(points: [start, bend], heads: heads)).shape == .freehand(points: [start, mid, bend], closed: false))
            #expect(project(.arrow(points: [start, bend, finish], heads: heads)).shape == .freehand(
                points: [start, bend, finish],
                closed: false
            ))
        }
    }

    @Test func intentsAreSentOnlyWhenTheyDifferFromHotSheetsDefault() {
        let box = NormRect(x: 10, y: 20, width: 30, height: 40)
        // Same defaults as UX Review: nothing sent, so no v4 marker.
        #expect(project(.rect(box)).intents == nil)
        #expect(project(.strike(box)).intents == nil)
        #expect(project(.insertion(start)).intents == nil)
        #expect(project(.arrow(points: [start, bend])).intents == nil)
        #expect(project(.arrow(points: [start, bend], heads: ArrowHeads(start: .flat, end: .flat))).intents == nil)
        #expect(project(.rect(box), intents: [.comment]).intents == nil)
        // Anything else, in order.
        #expect(project(.rect(box), intents: [.bug, .question]).intents == ["bug", "question"])
        #expect(project(.strike(box), intents: [.remove, .question]).intents == ["remove", "question"])
        #expect(project(.arrow(points: [start, bend]), intents: [.comment]).intents == ["comment"])
        #expect(project(.insertion(start), intents: [.change]).intents == ["change"])
    }

    @Test func theBoxIsHotSheetsPointBoxAndTheTextKeepsTheNumber() {
        let annotation = project(.arrow(points: [start, bend, finish], heads: ArrowHeads(start: .closed, end: .none)))
        #expect(NormRect(x: annotation.x, y: annotation.y, width: annotation.width, height: annotation.height) == NormRect(
            x: 100,
            y: 300,
            width: 600,
            height: 700
        ))
        #expect(annotation.text == "#3 n")
        #expect(project(.insertion(NormPoint(x: 10000, y: 0)), note: "").text == "#3")
        let corner = project(.insertion(NormPoint(x: 10000, y: 10000)))
        #expect(NormRect(x: corner.x, y: corner.y, width: corner.width, height: corner.height) == NormRect(
            x: 9999,
            y: 9999,
            width: 1,
            height: 1
        ))
    }

    @Test func theWireFormatIsHotSheetsTaggedShape() throws {
        let annotation = HotSheetMediaAnnotation(
            id: "a", x: 1, y: 2, width: 3, height: 4, startMs: nil, endMs: nil, text: "t",
            shape: .freehand(points: [start, bend, finish], closed: false), intents: ["bug"]
        )
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(annotation)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "x", "y", "width", "height", "text", "shape", "intents"])
        let shape = try #require(object["shape"] as? [String: Any])
        #expect(shape["type"] as? String == "freehand" && shape["closed"] as? Bool == false)
        #expect((shape["points"] as? [[String: Int]])?.first == ["x": 100, "y": 900])

        for value in [
            HotSheetShape.rect, .strike, .insertion(start), .arrow(points: [start, bend]), .freehand(
                points: [start, bend, finish],
                closed: true
            ),
        ] {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(HotSheetShape.self, from: data) == value)
        }
        // A closed freehand omits `closed` (Hot Sheet's default is true).
        let closed = try JSONEncoder().encode(HotSheetShape.freehand(points: [start, bend, finish], closed: true))
        #expect(String(bytes: closed, encoding: .utf8)?.contains("closed") == false)
        #expect(String(bytes: try JSONEncoder().encode(HotSheetShape.insertion(start)), encoding: .utf8)?.contains(#""point""#) == true)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HotSheetShape.self, from: Data(#"{"type":"star"}"#.utf8)) }
    }

    @Test func keptMeansHotSheetStoredTheShapeAndIntents() {
        let native = project(.strike(NormRect(x: 1, y: 1, width: 1, height: 1)), intents: [.bug])
        var dropped = native
        dropped.shape = nil
        dropped.intents = nil
        #expect(native.isKept(by: native))
        #expect(!native.isKept(by: dropped))
        var noIntents = native
        noIntents.intents = nil
        #expect(!native.isKept(by: noIntents))
        // A plain box asks for nothing beyond what any Hot Sheet keeps.
        let box = project(.rect(NormRect(x: 1, y: 1, width: 1, height: 1)))
        #expect(box.isKept(by: box))
    }

    // MARK: Submitting

    private func exampleFixture() throws -> (ReviewBundle, URL) {
        let bundle = try TestSupport.exampleBundle()
        let dir = try TestSupport.makeTempDirectory()
        for item in bundle.media {
            try Data("bytes".utf8).write(to: dir.appendingPathComponent(item.filename))
        }
        return (bundle, dir)
    }

    @Test(arguments: [FakeHotSheetClient.AnnotationDialect.native, .boxesOnly, .rejectsNative])
    func eachHotSheetGenerationEndsWithTheBestProjectionItKeeps(_ dialect: FakeHotSheetClient.AnnotationDialect) throws {
        let (bundle, dir) = try exampleFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = FakeHotSheetClient()
        client.annotationDialect = dialect
        try ReviewSubmitter(client: client).submit(bundle, mediaDirectory: dir)

        let composed = TicketComposer.compose(bundle)
        // The last write per capture is what Hot Sheet holds.
        var final: [String: [HotSheetMediaAnnotation]] = [:]
        for write in client.annotated {
            final[write.filename] = write.annotations
        }
        switch dialect {
        case .native:
            #expect(client.annotated.count == 2)
            #expect(final["capture-1.png"] == composed.hotSheetAnnotations["m1"])
            #expect(final["capture-2.mov"] == composed.hotSheetAnnotations["m2"])
        case .boxesOnly:
            // Native written, found stripped, then rewritten with intents in the text.
            #expect(client.annotated.map(\.filename) == ["capture-1.png", "capture-1.png", "capture-2.mov", "capture-2.mov"])
            #expect(final["capture-1.png"] == composed.legacyHotSheetAnnotations["m1"])
            #expect(final["capture-2.mov"] == composed.legacyHotSheetAnnotations["m2"])
        case .rejectsNative:
            #expect(client.annotated.count == 2)
            #expect(final["capture-1.png"] == composed.legacyHotSheetAnnotations["m1"])
            #expect(final["capture-2.mov"] == composed.legacyHotSheetAnnotations["m2"])
        }
    }

    @Test func theExamplesNativeProjection() throws {
        let native = try TicketComposer.compose(TestSupport.exampleBundle()).hotSheetAnnotations
        let shot = try #require(native["m1"])
        #expect(shot.map(\.shape) == [
            nil,
            .arrow(points: [NormPoint(x: 1200, y: 3000), NormPoint(x: 2600, y: 1800), NormPoint(x: 4500, y: 600)]),
            .strike,
            .insertion(NormPoint(x: 5200, y: 4100)),
            .freehand(points: [NormPoint(x: 6000, y: 4000), NormPoint(x: 6000, y: 4300), NormPoint(x: 6000, y: 4600)], closed: false),
        ])
        #expect(shot.map(\.intents) == [["change"], nil, nil, nil, nil])
        #expect(shot.first?.text == "#1 Primary button label is truncated at narrow widths.")
        let clip = try #require(native["m2"]?.first)
        #expect(clip.intents == ["bug"] && clip.startMs == 2500 && clip.endMs == 4250)
        #expect(clip.shape == .freehand(
            points: [NormPoint(x: 400, y: 1000), NormPoint(x: 3000, y: 900), NormPoint(x: 3200, y: 7000), NormPoint(x: 500, y: 7200)],
            closed: true
        ))
    }
}
