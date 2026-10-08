import Foundation
import Testing
@testable import UXReviewKit

/// Adding only part of a review to an existing ticket (HS2-00TXV6, docs/07 §7.2.2): the selection's
/// transitions, the session's issue, the filtered batch and note numbering, what stays in the
/// draft, a resumed note keeping its selection, and `--exclude`.
struct ReviewSelectionTests {
    static func annotation(_ id: String, _ mediaId: String) -> Annotation {
        Annotation(id: id, mediaId: mediaId, shape: .insertion(NormPoint(x: 5000, y: 5000)), note: id)
    }

    static let bundle = ReviewBundle(
        id: "r", title: "t", createdAt: Date(timeIntervalSince1970: 0),
        media: [
            TestSupport.video("m1", filename: "a.mov"),
            TestSupport.video("m2", filename: "b.mov"),
            TestSupport.video("m3", filename: "c.mov"),
        ],
        annotations: [annotation("a1", "m1"), annotation("a2", "m1"), annotation("a3", "m2"), annotation("a4", "m3")]
    )

    static func ids(_ bundle: ReviewBundle) -> String {
        bundle.media.map(\.id).joined(separator: ",") + "|" + bundle.annotations.map(\.id).joined(separator: ",")
    }

    @Test func transitionsAcrossCapturesAndAnnotations() {
        var selection = ReviewSelection()
        #expect(selection.isEverything && Self.ids(selection.apply(to: Self.bundle)) == "m1,m2,m3|a1,a2,a3,a4")

        // Leave a capture out: its annotations go with it.
        selection.set(media: "m2", included: false)
        #expect(Self.ids(selection.apply(to: Self.bundle)) == "m1,m3|a1,a2,a4")
        // Leave out one annotation of an included capture.
        selection.set(Self.bundle.annotations[1], included: false, in: Self.bundle)
        #expect(Self.ids(selection.apply(to: Self.bundle)) == "m1,m3|a1,a4")
        // Repeating either is harmless.
        selection.set(media: "m2", included: false)
        selection.set(Self.bundle.annotations[1], included: false, in: Self.bundle)
        #expect(Self.ids(selection.apply(to: Self.bundle)) == "m1,m3|a1,a4")
        // Including the capture again keeps the annotation choices made on others.
        selection.set(media: "m2", included: true)
        #expect(Self.ids(selection.apply(to: Self.bundle)) == "m1,m2,m3|a1,a3,a4")

        // Including an annotation of a left-out capture brings the capture back with only it.
        selection.set(media: "m1", included: false)
        selection.set(Self.bundle.annotations[1], included: true, in: Self.bundle)
        #expect(Self.ids(selection.apply(to: Self.bundle)) == "m1,m2,m3|a2,a3,a4")

        // Everything left out, then everything back.
        for id in ["m1", "m2", "m3"] {
            selection.set(media: id, included: false)
        }
        #expect(selection.apply(to: Self.bundle).media.isEmpty && selection.apply(to: Self.bundle).annotations.isEmpty)
        for id in ["m1", "m2", "m3"] {
            selection.set(media: id, included: true)
        }
        #expect(Self.ids(selection.apply(to: Self.bundle)) == "m1,m2,m3|a2,a3,a4")
    }

    /// Ids that left the review are forgotten; captures added later are included.
    @Test func prunedToTheDraft() {
        let selection = ReviewSelection(excludedMedia: ["m2", "gone"], excludedAnnotations: ["a1", "a9"])
        var smaller = Self.bundle
        smaller.media.removeAll { $0.id == "m2" }
        smaller.annotations.removeAll { $0.mediaId == "m2" }
        #expect(selection.pruned(to: smaller) == ReviewSelection(excludedAnnotations: ["a1"]))
        var larger = Self.bundle
        larger.media.append(TestSupport.video("m4", filename: "d.mov"))
        #expect(selection.apply(to: larger).media.map(\.id) == ["m1", "m3", "m4"])
    }

    /// Leaving every capture out blocks adding to an existing ticket (not filing a new one); a
    /// refresh that removes the excluded capture lifts it; nothing changes while submitting.
    @Test func sessionIssueAndPhases() {
        var session = ReviewSessionTests.session(Self.bundle)
        session.setSelection(ReviewSelection(excludedMedia: ["m1", "m2", "m3"]))
        #expect(!session.issues.contains(.ticket(.nothingSelected)))
        #expect(session.selectedBundle == Self.bundle)
        session.setDestination(.existingTicket)
        #expect(session.issues.contains(.ticket(.nothingSelected)))
        #expect(SessionIssue.ticket(.nothingSelected).message(in: Self.bundle) == "Choose at least one capture to add.")
        #expect(session.selectedBundle.media.isEmpty)

        session.setSelection(ReviewSelection(excludedMedia: ["m2"]))
        #expect(!session.issues.contains(.ticket(.nothingSelected)))
        var removed = Self.bundle
        removed.media.removeAll { $0.id == "m2" }
        removed.annotations.removeAll { $0.mediaId == "m2" }
        session.refresh(removed, missingFiles: [])
        #expect(session.selection.isEverything)

        var submitting = ReviewSessionTests.session(Self.bundle)
        submitting.beginSubmit()
        let applied = submitting.setSelection(ReviewSelection(excludedMedia: ["m1"]))
        #expect(!applied)
        #expect(submitting.selection.isEverything)
    }

    @Test func excludeParsesAndMapsToTheReview() throws {
        let command = try #require(try SubmitCommand.parse(["--submit", "--to-ticket", "HS-1ABC", "--exclude", "m2, a1,,"]))
        #expect(command.exclude == ["m2", "a1"])
        #expect(try command.selection(in: Self.bundle) == ReviewSelection(excludedMedia: ["m2"], excludedAnnotations: ["a1"]))
        #expect(throws: CommandLineError.invalidValue("--exclude", "m9,x")) {
            try SubmitCommand(exclude: ["m9", "a1", "x"]).selection(in: Self.bundle)
        }
        #expect(throws: CommandLineError.invalidValue("--exclude", "needs --to-ticket")) {
            try SubmitCommand.parse(["--submit", "--exclude", "m1"])
        }
        #expect(throws: CommandLineError.invalidValue("--exclude", "")) {
            try SubmitCommand.parse(["--submit", "--to-ticket", "HS-1ABC", "--exclude", ","])
        }
        #expect(try SubmitCommand.parse(["--submit"])?.exclude == [])
    }
}

/// `DraftSubmitter` with a selection: only the chosen files and annotations go, the note numbers
/// them from #1, and the draft keeps the rest.
struct PartialReviewSubmitterTests {
    typealias Fixture = DraftSubmitterTests.Fixture
    static let existing = ExistingTicketSubmitterTests.existing

    @Test func addsOnlyTheSelectionAndKeepsTheRest() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 3) // m1 png, m2 mov, m3 png; one annotation each
        // A second annotation on m1, left out; m2 left out entirely.
        try fixture.store.update(draft.directory) { bundle in
            bundle.annotations.append(Annotation(
                id: "a-extra", mediaId: "m1", shape: .rect(NormRect(x: 0, y: 0, width: 50, height: 50)), note: "later"
            ))
        }
        let selection = ReviewSelection(excludedMedia: ["m2"], excludedAnnotations: ["a-extra"])
        let result = try fixture.submitter().submit(draft.directory, title: "Part", into: Self.existing, selection: selection)

        #expect(result.mediaCount == 2 && result.annotationCount == 2)
        #expect(result.remainingCaptures == 2 && !result.draftRemoved)
        let batch = try #require(fixture.client.attached.first)
        #expect(batch.files.map(\.lastPathComponent) == ["capture-1.png", "capture-3.png", "review.json"])
        let note = try #require(fixture.client.notes.first?.markdown)
        #expect(note.contains("#### #1 · comment · `attachment:capture-1.png`"))
        #expect(note.contains("#### #2 · comment · `attachment:capture-3.png`"))
        #expect(!note.contains("#3") && !note.contains("capture-2.mov") && !note.contains("later"))

        // The draft keeps m2 with its annotation and m1 with the left-out one; m3 is gone.
        let left = try fixture.store.load(draft.directory).bundle
        #expect(left.media.map(\.id) == ["m1", "m2"])
        #expect(left.annotations.map(\.id).sorted() == ["a-extra", "a-m2"])
        #expect(!fixture.exists(draft.directory.appendingPathComponent("capture-3.png")))
        #expect(fixture.exists(draft.directory.appendingPathComponent("capture-1.png")))
        #expect(fixture.store.pendingSubmission(in: draft.directory) == nil)
        #expect(fixture.store.isCurrent(draft.directory))

        // Then the rest, all of it: the draft is filed and deleted as usual.
        let rest = try fixture.submitter().submit(draft.directory, into: Self.existing)
        #expect(rest.mediaCount == 2 && rest.annotationCount == 2 && rest.remainingCaptures == nil && rest.draftRemoved)
        #expect(!fixture.exists(draft.directory))
    }

    /// A selection that sends every capture but leaves no annotation behind deletes the draft.
    @Test func aSelectionThatLeavesNothingDeletesTheDraft() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 2)
        // Everything selected but expressed with a now-gone id: pruned to everything.
        let result = try fixture.submitter().submit(
            draft.directory, into: Self.existing, selection: ReviewSelection(excludedMedia: ["m9"])
        )
        #expect(result.remainingCaptures == nil && result.draftRemoved)
        #expect(!fixture.exists(draft.directory))
    }

    /// A note that fails records the selection; the retry sends that part even when asked for
    /// another, never attaches again, and then keeps the rest.
    @Test func aRetryKeepsTheSelectionItStartedWith() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 2)
        fixture.client.noteErrors = [HotSheetError.commandFailed(command: "edit", exitCode: 1, stderr: "busy")]
        let first = ReviewSelection(excludedMedia: ["m2"])
        #expect(throws: SubmissionFailure.self) {
            try fixture.submitter().submit(draft.directory, into: Self.existing, selection: first)
        }
        #expect(fixture.store.pendingSubmission(in: draft.directory)?.selection == first)
        // The part is staged apart: the draft's own review.json still holds everything.
        #expect(try fixture.store.load(draft.directory).bundle.media.count == 2)
        #expect(try fixture.store.load(draft.directory).bundle.annotations.count == 2)
        #expect(fixture.client.attached.first?.files.allSatisfy { $0.path.contains("/.submission/") } == true)

        let result = try fixture.submitter().submit(draft.directory, into: Self.existing, selection: ReviewSelection())
        #expect(result.mediaCount == 1 && result.remainingCaptures == 1)
        #expect(fixture.client.attached.count == 1)
        #expect(fixture.client.notes.count == 1 && fixture.client.notes[0].markdown.contains("capture-1.png"))
        #expect(!fixture.client.notes[0].markdown.contains("capture-2.mov"))
        #expect(try fixture.store.load(draft.directory).bundle.media.map(\.id) == ["m2"])
    }

    @Test func nothingSelectedSendsNothing() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 1)
        #expect(throws: SubmissionFailure(message: "Choose at least one capture to add.")) {
            try fixture.submitter().submit(draft.directory, into: Self.existing, selection: ReviewSelection(excludedMedia: ["m1"]))
        }
        #expect(fixture.client.attached.isEmpty && fixture.client.notes.isEmpty && fixture.exists(draft.directory))
    }
}
