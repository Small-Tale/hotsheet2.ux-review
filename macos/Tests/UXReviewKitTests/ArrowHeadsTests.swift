import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// Arrow heads at each end (`HS2-HQV9R8`): the bundle format, the default intent they imply, the
/// editor's undoable edit and every transform that must carry them, the headless script op, the
/// ticket text, and VoiceOver. Spec: docs/02-review-bundle.md §2.4, docs/06-annotation-editor.md §6.5.
struct ArrowHeadsTests {
    static let points = [NormPoint(x: 1000, y: 1000), NormPoint(x: 5000, y: 3000)]
    static let span = ArrowHeads(start: .flat, end: .flat)

    static func decode(_ json: String) throws -> Shape {
        try JSONDecoder().decode(Shape.self, from: Data(json.utf8))
    }

    static func encode(_ shape: Shape) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(shape)) as? [String: Any])
    }

    // MARK: Bundle format

    @Test func theStandardArrowWritesNoHeads() throws {
        let object = try Self.encode(.arrow(points: Self.points))
        #expect(object["startHead"] == nil)
        #expect(object["endHead"] == nil)
        #expect(Set(object.keys) == ["type", "points"])
    }

    @Test func onlyHeadsThatDifferFromTheStandardAreWritten() throws {
        let startOnly = try Self.encode(.arrow(points: Self.points, heads: ArrowHeads(start: .openCircle, end: .closed)))
        #expect(startOnly["startHead"] as? String == "openCircle")
        #expect(startOnly["endHead"] == nil)
        let endOnly = try Self.encode(.arrow(points: Self.points, heads: ArrowHeads(start: .none, end: .open)))
        #expect(endOnly["startHead"] == nil)
        #expect(endOnly["endHead"] as? String == "open")
    }

    /// Every combination survives a round trip.
    @Test func everyCombinationRoundTrips() throws {
        for start in ArrowHead.allCases {
            for end in ArrowHead.allCases {
                let shape = Shape.arrow(points: Self.points, heads: ArrowHeads(start: start, end: end))
                let decoded = try JSONDecoder().decode(Shape.self, from: JSONEncoder().encode(shape))
                #expect(decoded == shape, "\(start) → \(end)")
            }
        }
    }

    /// Bundles written before heads existed read as the standard arrow.
    @Test func olderArrowsReadAsTheStandardArrow() throws {
        let shape = try Self.decode(#"{"type": "arrow", "points": [{"x": 1, "y": 2}, {"x": 3, "y": 4}]}"#)
        #expect(shape == .arrow(points: [NormPoint(x: 1, y: 2), NormPoint(x: 3, y: 4)], heads: .standard))
        // One head given: the other is the standard one.
        let start = try Self.decode(#"{"type": "arrow", "startHead": "flat", "points": [{"x": 1, "y": 2}, {"x": 3, "y": 4}]}"#)
        #expect(start == .arrow(points: [NormPoint(x: 1, y: 2), NormPoint(x: 3, y: 4)], heads: ArrowHeads(start: .flat, end: .closed)))
    }

    @Test func anUnknownHeadIsRejected() {
        #expect(throws: DecodingError.self) {
            try Self.decode(#"{"type": "arrow", "endHead": "diamond", "points": [{"x": 1, "y": 2}, {"x": 3, "y": 4}]}"#)
        }
    }

    @Test func theSchemaListsEveryHead() throws {
        let url = TestSupport.repoRoot.appendingPathComponent("spec/review-bundle.schema.json")
        let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let defs = try #require(schema["$defs"] as? [String: Any])
        let heads = try #require((defs["arrowHead"] as? [String: Any])?["enum"] as? [String])
        #expect(heads == ArrowHead.allCases.map(\.rawValue))
    }

    @Test func theExampleHasASpan() throws {
        let bundle = try TestSupport.exampleBundle()
        let span = try #require(bundle.annotations.first { $0.id == "a6" })
        #expect(span.shape == .arrow(points: [NormPoint(x: 6000, y: 4000), NormPoint(x: 6000, y: 4600)], heads: Self.span))
        #expect(span.effectiveIntents == [.comment])
    }

    // MARK: Default intent

    /// Move exactly when an arrowhead (open or closed) is at one end and nothing at the other.
    @Test func onlyAOneWayArrowDefaultsToMove() {
        for start in ArrowHead.allCases {
            for end in ArrowHead.allCases {
                let oneWay = (end.pointsTheWay && start == .none) || (start.pointsTheWay && end == .none)
                let shape = Shape.arrow(points: Self.points, heads: ArrowHeads(start: start, end: end))
                #expect(shape.defaultIntent == (oneWay ? .move : .comment), "\(start) → \(end)")
            }
        }
        #expect(ArrowHeads.standard.pointsOneWay)
        #expect(ArrowHeads(start: .open, end: .none).pointsOneWay) // drawn backwards still points
        #expect(!ArrowHeads(start: .closed, end: .closed).pointsOneWay)
        #expect(!ArrowHeads(start: .none, end: .none).pointsOneWay)
        #expect(!ArrowHeads(start: .none, end: .closedCircle).pointsOneWay)
    }

    @Test func summaryNamesNonStandardHeadsOnly() {
        #expect(ArrowHeads.standard.summary == nil)
        #expect(Self.span.summary == "start flat, end flat")
        #expect(ArrowHeads(start: .openCircle, end: .closedCircle).summary == "start open circle, end closed circle")
        #expect(Shape.rect(NormRect(x: 0, y: 0, width: 1, height: 1)).arrowHeadsSummary == nil)
    }

    // MARK: Editor

    static func editorWithArrow() -> AnnotationEditor {
        var editor = AnnotationEditorTests.editor()
        AnnotationEditorTests.draw(&editor, .arrow, [AnnotationEditorTests.p(100, 100), AnnotationEditorTests.p(400, 300)])
        return editor
    }

    static func heads(_ editor: AnnotationEditor, _ id: String = "a1") -> ArrowHeads? {
        if case let .arrow(_, heads)? = editor.annotation(id)?.shape { heads } else { nil }
    }

    @Test func newArrowsAreStandard() {
        let editor = Self.editorWithArrow()
        #expect(Self.heads(editor) == .standard)
        #expect(editor.annotation("a1")?.effectiveIntents == [.move])
    }

    /// Set, set again, undo twice, redo, and a no-op: each real change is one undo step.
    @Test func settingHeadsIsUndoable() {
        var editor = Self.editorWithArrow()
        let depth = editor.undoStack.count
        let changed1 = editor.setArrowHeads(ArrowHeads(start: .closed, end: .closed), for: "a1")
        #expect(changed1)
        let changed2 = editor.setArrowHeads(Self.span, for: "a1")
        #expect(changed2)
        #expect(editor.undoStack.count == depth + 2)
        #expect(Self.heads(editor) == Self.span)
        #expect(editor.annotation("a1")?.effectiveIntents == [.comment]) // a span is a comment
        editor.undo()
        #expect(Self.heads(editor) == ArrowHeads(start: .closed, end: .closed))
        editor.undo()
        #expect(Self.heads(editor) == .standard)
        #expect(editor.annotation("a1")?.effectiveIntents == [.move])
        editor.redo()
        #expect(Self.heads(editor) == ArrowHeads(start: .closed, end: .closed))
        // The same heads again: nothing changes and history stays put.
        let before = editor.undoStack.count
        let changed3 = editor.setArrowHeads(ArrowHeads(start: .closed, end: .closed), for: "a1")
        #expect(!changed3)
        #expect(editor.undoStack.count == before)
    }

    @Test func headsOnlyApplyToArrows() {
        var editor = AnnotationEditorTests.editor()
        AnnotationEditorTests.draw(&editor, .rect, [AnnotationEditorTests.p(100, 100), AnnotationEditorTests.p(300, 200)])
        let depth = editor.undoStack.count
        let changed4 = editor.setArrowHeads(Self.span, for: "a1")
        #expect(!changed4)
        let changed5 = editor.setArrowHeads(Self.span, for: "missing")
        #expect(!changed5)
        #expect(editor.undoStack.count == depth)
        #expect(editor.annotation("a1")?.shape.kind == "rect")
    }

    /// Intents the reviewer chose stay when the heads change; only the default follows them.
    @Test func chosenIntentsSurviveAHeadChange() {
        var editor = Self.editorWithArrow()
        editor.toggleIntent(.bug, for: "a1")
        #expect(editor.annotation("a1")?.intents == [.bug, .move])
        editor.setArrowHeads(Self.span, for: "a1")
        #expect(editor.annotation("a1")?.intents == [.bug, .move])
    }

    /// Moving, reshaping, duplicating, and cropping keep the heads.
    @Test func everyTransformKeepsTheHeads() throws {
        var editor = Self.editorWithArrow()
        editor.setArrowHeads(Self.span, for: "a1")
        editor.select("a1")
        editor.nudgeSelection(dx: 10, dy: 5)
        #expect(Self.heads(editor) == Self.span)
        // Drag the head vertex.
        editor.setTool(.select)
        AnnotationEditorTests.drag(&editor, [AnnotationEditorTests.p(410, 305), AnnotationEditorTests.p(500, 350)])
        #expect(Self.heads(editor) == Self.span)
        editor.select("a1")
        editor.duplicateSelection()
        let copy = try #require(editor.bundle.annotations.last)
        #expect(copy.id != "a1")
        #expect(Self.heads(editor, copy.id) == Self.span)

        let frame = MediaFrame(width: 1000, height: 500)
        let shape = try #require(editor.annotation("a1")?.shape)
        let cropped = try #require(ImageCrop.transform(shape, from: frame, crop: PixelRect(x: 0, y: 0, width: 800, height: 400)))
        guard case let .arrow(_, heads) = cropped else { throw CropFailure.notAnArrow }
        #expect(heads == Self.span)
    }

    enum CropFailure: Error { case notAnArrow }

    @Test func voiceOverReadsNonStandardHeads() {
        var editor = Self.editorWithArrow()
        #expect(editor.accessibilityLabel(for: "a1") == "Annotation 1: Arrow, move. No note.")
        editor.setArrowHeads(Self.span, for: "a1")
        #expect(editor.accessibilityLabel(for: "a1") == "Annotation 1: Arrow, start flat, end flat, comment. No note.")
    }

    // MARK: Headless script

    @Test func theHeadsOpParsesAndKeepsAMissingEnd() throws {
        let script = try EditorScript.parse(Data(#"""
        {"steps": [{"op": "heads", "start": "flat", "end": "openCircle"}, {"op": "heads", "end": "none"}]}
        """#.utf8))
        #expect(script.steps == [.heads(start: .flat, end: .openCircle), .heads(start: nil, end: ArrowHead.none)])
        #expect(throws: (any Error).self) { try EditorScript.parse(Data(#"{"steps": [{"op": "heads"}]}"#.utf8)) }
        #expect(throws: (any Error).self) { try EditorScript.parse(Data(#"{"steps": [{"op": "heads", "end": "star"}]}"#.utf8)) }
    }

    // MARK: Ticket text

    @Test func theTicketNamesTheHeads() throws {
        let details = try TicketComposer.compose(TestSupport.exampleBundle()).ticket.details
        #expect(details.contains("### #6 · comment · `attachment:capture-1.png`"))
        #expect(details.contains("- Shape: arrow (start flat, end flat); region (0–10000): x 6000, y 4000, w 1, h 600"))
        // The standard arrow's line is unchanged.
        #expect(details.contains("- Shape: arrow; region (0–10000): x 1200, y 600, w 3300, h 2400"))
    }

    // MARK: Drawing

    @Test func theLineStopsAtAnOpenCircle() {
        let width: CGFloat = 3
        let radius = AnnotationRenderer.circleRadius(width: width)
        #expect(AnnotationRenderer.headInset(.openCircle, width: width) == radius)
        for head in ArrowHead.allCases where head != .openCircle {
            #expect(AnnotationRenderer.headInset(head, width: width) == 0)
        }
        let moved = AnnotationRenderer.inset(CGPoint(x: 0, y: 0), toward: CGPoint(x: 100, y: 0), by: radius)
        #expect(abs(moved.x - radius) < 1e-9 && moved.y == 0)
        // Never past the other point, and a zero-length segment stays put.
        #expect(AnnotationRenderer.inset(CGPoint(x: 0, y: 0), toward: CGPoint(x: 4, y: 0), by: 50) == CGPoint(x: 4, y: 0))
        #expect(AnnotationRenderer.inset(CGPoint(x: 5, y: 5), toward: CGPoint(x: 5, y: 5), by: 9) == CGPoint(x: 5, y: 5))
    }
}
