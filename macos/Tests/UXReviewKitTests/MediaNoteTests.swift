import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// HS2-KVDDFH: a note about a capture as a whole, in review.json (docs/02 §2.2), the editor
/// (docs/06 §6.5.2), and the ticket's media list (docs/03 §3.3, §3.5).
struct MediaNoteTests {
    typealias Fixture = AnnotationEditorTests

    // MARK: review.json

    @Test func theNoteRoundTripsAndIsOmittedWhenThereIsNone() throws {
        var item = TestSupport.image()
        let plain = try #require(String(bytes: ReviewBundle.makeEncoder().encode(item), encoding: .utf8))
        #expect(!plain.contains("\"note\""))
        item.note = "Feels **cramped**.\nGive the form room."
        let data = try ReviewBundle.makeEncoder().encode(item)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["note"] as? String == "Feels **cramped**.\nGive the form room.")
        #expect(try ReviewBundle.makeDecoder().decode(MediaItem.self, from: data) == item)
        // An older bundle without the field reads as no note.
        let older =
            Data(
                #"{"id":"m1","filename":"a.png","kind":"image","pixelWidth":10,"pixelHeight":10,"capturedAt":"2026-10-07T02:58:10Z"}"#
                    .utf8
            )
        #expect(try ReviewBundle.makeDecoder().decode(MediaItem.self, from: older).note == nil)
    }

    @Test func theSpecExampleCarriesACaptureNote() throws {
        let bundle = try ReviewBundle.makeDecoder().decode(ReviewBundle.self, from: Data(contentsOf: TestSupport.exampleBundleURL))
        #expect(bundle.media.first?.note?.hasPrefix("The whole window feels cramped") == true)
        #expect(bundle.media.last?.note == nil)
        #expect(bundle.validate().isEmpty)
    }

    // MARK: Editor

    @Test func typingIsOneUndoStepAndAnEmptyNoteIsNone() {
        var editor = Fixture.editor(media: [Fixture.media("m1"), Fixture.media("m2")])
        let changed1 = editor.setMediaNote("C", for: "m1")
        #expect(changed1)
        let changed2 = editor.setMediaNote("Cr", for: "m1")
        #expect(changed2)
        let changed3 = editor.setMediaNote("Cramped", for: "m1")
        #expect(changed3)
        #expect(editor.bundle.media[0].note == "Cramped")
        #expect(editor.bundle.media[1].note == nil)
        // Another capture's note is its own step.
        let changed4 = editor.setMediaNote("Fine", for: "m2")
        #expect(changed4)
        editor.undo()
        #expect(editor.bundle.media[1].note == nil)
        editor.undo()
        #expect(editor.bundle.media[0].note == nil)
        editor.redo()
        #expect(editor.bundle.media[0].note == "Cramped")
        // Clearing stores no note; the same text again changes nothing and adds no history.
        let changed5 = editor.setMediaNote("", for: "m1")
        #expect(changed5)
        #expect(editor.bundle.media[0].note == nil)
        let changed6 = editor.setMediaNote("", for: "m1")
        #expect(!changed6)
        let changed7 = editor.setMediaNote("x", for: "nope")
        #expect(!changed7)
        editor.undo()
        #expect(editor.bundle.media[0].note == "Cramped")
    }

    /// Annotation notes and the capture note interleaved: each run of typing coalesces on its own.
    @Test func interleavedWithAnAnnotationNote() {
        var editor = Fixture.editor()
        Fixture.draw(&editor, .rect, [Fixture.p(100, 100), Fixture.p(300, 200)])
        editor.setNote("A", for: "a1")
        editor.setMediaNote("M", for: "m1")
        editor.setMediaNote("Me", for: "m1")
        editor.setNote("Ab", for: "a1")
        editor.undo()
        #expect(editor.annotation("a1")?.note == "A")
        #expect(editor.bundle.media[0].note == "Me")
        editor.undo()
        #expect(editor.bundle.media[0].note == nil)
        #expect(editor.annotation("a1")?.note == "A")
    }

    @Test func theScriptOpParses() throws {
        let script = try EditorScript.parse(Data(#"{"steps": [{"op": "media-note", "media": "m1", "text": "Cramped"}]}"#.utf8))
        #expect(script.steps == [.mediaNote("m1", "Cramped")])
        #expect(throws: (any Error).self) { try EditorScript.parse(Data(#"{"steps": [{"op": "media-note", "media": "m1"}]}"#.utf8)) }
    }

    // MARK: Saving (real files)

    /// Saved to the draft, read back by a new editor, kept when a capture is added meanwhile, and
    /// removed from disk once cleared. (Before the fix, save copied only sizes back to disk.)
    @Test func theNoteIsSavedReloadedAndCleared() throws {
        let fixture = try EditorSessionTests.Fixture()
        let session = try fixture.session()
        session.editor.setMediaNote("Feels cramped.", for: "m1")
        #expect(session.editor.isDirty)
        try session.save()
        #expect(try fixture.onDisk().media[0].note == "Feels cramped.")
        #expect(try fixture.session().editor.bundle.media[0].note == "Feels cramped.")

        try fixture.store.add(fixture.capture(capturedAt: Date(timeIntervalSince1970: 5)), to: fixture.draft.directory)
        try session.save()
        #expect(try fixture.onDisk().media.map(\.note) == ["Feels cramped.", nil])

        try EditorScript(steps: [.mediaNote("m1", "")]).run(on: session)
        let raw = try String(contentsOf: fixture.draft.directory.appendingPathComponent("review.json"), encoding: .utf8)
        #expect(!raw.contains("\"note\" : \"\"") && !raw.contains("Feels cramped"))
        #expect(throws: EditorScriptError.self) { try EditorScript(steps: [.mediaNote("m9", "x")]).run(on: session) }
    }

    // MARK: Ticket

    private func bundle() -> ReviewBundle {
        var one = TestSupport.image("m1", filename: "capture-1.png")
        one.note = "The whole page feels cramped.\n\n- More room\n- Bigger type"
        let two = TestSupport.image("m2", filename: "capture-2.png")
        return TestSupport.bundle(media: [one, two])
    }

    @Test func theMediaListShowsTheNoteInsideTheCapturesItem() {
        let section = TicketComposer.mediaSection(bundle())
        #expect(section.contains("""
        - `attachment:capture-1.png` (image, 100×50)
          Capture note: The whole page feels cramped.

          - More room
          - Bigger type
        - `attachment:capture-2.png` (image, 100×50)
        """))
        #expect(!TicketComposer.mediaSection(TestSupport.bundle()).contains("Capture note"))
    }

    @Test func bothTicketKindsCarryIt() {
        #expect(TicketComposer.compose(bundle()).ticket.details.contains("  Capture note: The whole page feels cramped."))
        #expect(TicketComposer.note(for: bundle()).contains("  Capture note: The whole page feels cramped."))
    }

    /// Left out of an existing-ticket submission, a capture takes its note with it.
    @Test func aLeftOutCaptureTakesItsNoteAlong() {
        var selection = ReviewSelection()
        selection.set(media: "m1", included: false)
        let filed = selection.apply(to: bundle())
        #expect(filed.media.map(\.id) == ["m2"])
        #expect(!TicketComposer.note(for: filed).contains("Capture note"))
        selection.set(media: "m1", included: true)
        #expect(selection.apply(to: bundle()).media[0].note?.hasPrefix("The whole page") == true)
    }
}
