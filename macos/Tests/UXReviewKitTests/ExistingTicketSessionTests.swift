import Foundation
import Testing
@testable import UXReviewKit

/// The destination half of the session state machine (docs/07 §7.4): every lookup state × every
/// input, the phase rules, and realistic and adversarial sequences (switching back and forth,
/// slug edits while a lookup runs, empty then refilled, the project changing underneath).
struct ExistingTicketSessionTests {
    static let storeA = HotSheetStatus(cliPath: "/bin/hotsheet-cli", projectDirectory: "/a", storePath: "/a.hs2")
    static let storeB = HotSheetStatus(cliPath: "/bin/hotsheet-cli", projectDirectory: "/b", storePath: "/b.hs2")
    static let noStore = HotSheetStatus(cliPath: "/bin/hotsheet-cli", problem: "No project selected.")
    static let query1 = TicketQuery(reference: "HS-1ABC", storePath: "/a.hs2")
    static let ticket1 = HotSheetTicket(id: "01M4CCW6AW9EHFYT2QTZJ70H8D", slug: "HS-1ABC", title: "Existing", status: "started")

    static func session(target: HotSheetStatus = storeA) -> ReviewSession {
        ReviewSessionTests.session(target: target)
    }

    /// Short names for lookup states, so the matrix reads as a table.
    static func name(_ lookup: TicketLookup) -> String {
        switch lookup {
        case .empty: "empty"
        case .unrecognized: "unrecognized"
        case let .noStore(reference): "noStore(\(reference))"
        case let .looking(query): "looking(\(query.reference)@\(query.storePath))"
        case let .found(query, _): "found(\(query.reference)@\(query.storePath))"
        case let .notFound(query): "notFound(\(query.reference)@\(query.storePath))"
        case let .failed(query, _): "failed(\(query.reference)@\(query.storePath))"
        }
    }

    enum Start: String, CaseIterable { case empty, unrecognized, looking, found, notFound, failed, noStore }
    enum Input: String, CaseIterable {
        case clear, junk, sameSlug, sameSlugOtherCase, otherSlug, resolveCurrent, resolveStale, storeB, noStore, storeA
    }

    static func session(in start: Start) -> ReviewSession {
        var session = session(target: start == .noStore ? noStore : storeA)
        session.setDestination(.existingTicket)
        switch start {
        case .empty: break
        case .unrecognized: session.editTicket("junk")
        case .looking, .noStore: session.editTicket("HS-1ABC")
        case .found:
            session.editTicket("HS-1ABC")
            session.resolveLookup(query1, .success(ticket1))
        case .notFound:
            session.editTicket("HS-1ABC")
            session.resolveLookup(query1, .success(nil))
        case .failed:
            session.editTicket("HS-1ABC")
            session.resolveLookup(query1, .failure(SubmissionFailure(message: "locked")))
        }
        return session
    }

    static func apply(_ input: Input, to session: inout ReviewSession) {
        switch input {
        case .clear: session.editTicket("  ")
        case .junk: session.editTicket("no ticket here")
        case .sameSlug: session.editTicket("HS-1ABC")
        case .sameSlugOtherCase: session.editTicket(" hs-1abc ")
        case .otherSlug: session.editTicket("HS-2XYZ")
        case .resolveCurrent: session.resolveLookup(query1, .success(ticket1))
        case .resolveStale: session.resolveLookup(TicketQuery(reference: "HS-2XYZ", storePath: "/a.hs2"), .success(ticket1))
        case .storeB: session.setTarget(storeB)
        case .noStore: session.setTarget(noStore)
        case .storeA: session.setTarget(storeA)
        }
    }

    @Test func lookupTransitionMatrix() {
        let looking1 = "looking(HS-1ABC@/a.hs2)", looking2 = "looking(HS-2XYZ@/a.hs2)", lookingB = "looking(HS-1ABC@/b.hs2)"
        let start: [Start: String] = [
            .empty: "empty", .unrecognized: "unrecognized", .looking: looking1, .found: "found(HS-1ABC@/a.hs2)",
            .notFound: "notFound(HS-1ABC@/a.hs2)", .failed: "failed(HS-1ABC@/a.hs2)", .noStore: "noStore(HS-1ABC)",
        ]
        // Expected state after each input; a missing entry means "unchanged".
        let parsed: [Start] = [.looking, .found, .notFound, .failed, .noStore]
        let expected: [Input: [Start: String]] = [
            .clear: Dictionary(uniqueKeysWithValues: Start.allCases.map { ($0, "empty") }),
            .junk: Dictionary(uniqueKeysWithValues: Start.allCases.map { ($0, "unrecognized") }),
            .sameSlug: [.empty: looking1, .unrecognized: looking1],
            .sameSlugOtherCase: [.empty: looking1, .unrecognized: looking1],
            .otherSlug: [
                .empty: looking2,
                .unrecognized: looking2,
                .looking: looking2,
                .found: looking2,
                .notFound: looking2,
                .failed: looking2,
                .noStore: "noStore(HS-2XYZ)",
            ],
            .resolveCurrent: [.looking: "found(HS-1ABC@/a.hs2)"],
            .resolveStale: [:],
            .storeB: Dictionary(uniqueKeysWithValues: parsed.map { ($0, lookingB) }),
            .noStore: Dictionary(uniqueKeysWithValues: parsed.map { ($0, "noStore(HS-1ABC)") }),
            .storeA: [.noStore: looking1],
        ]
        for state in Start.allCases {
            for input in Input.allCases {
                var session = Self.session(in: state)
                #expect(Self.name(session.ticketLookup) == start[state], "start \(state)")
                Self.apply(input, to: &session)
                let want = expected[input]?[state] ?? start[state]
                #expect(Self.name(session.ticketLookup) == want, "\(state) + \(input)")
            }
        }
    }

    @Test func onlyAFoundOpenTicketCanBeSubmittedTo() {
        let messages: [Start: String?] = [
            .empty: "Enter the ticket to add this review to.",
            .unrecognized: "“junk” isn't a ticket. Enter a slug such as HS-ABC123.",
            .looking: "Looking up HS-1ABC…",
            .found: nil,
            .notFound: "No ticket HS-1ABC in a.hs2.",
            .failed: "Couldn't look up HS-1ABC: locked",
            .noStore: nil, // the project problem blocks instead
        ]
        for (state, message) in messages {
            let session = Self.session(in: state)
            let ticketIssues = session.issues.filter { if case .ticket = $0 { true } else { false } }
            #expect(ticketIssues.map { $0.message(in: session.bundle) } == (message.map { [$0] } ?? []), "\(state)")
            #expect(session.canSubmit == (state == .found), "\(state)")
            #expect((session.existingTicket != nil) == (state == .found), "\(state)")
            #expect(session.pendingLookup == (state == .looking ? Self.query1 : nil), "\(state)")
        }
        var deleted = Self.session(in: .looking)
        var closed = Self.ticket1
        closed.status = "deleted"
        deleted.resolveLookup(Self.query1, .success(closed))
        #expect(deleted.issues == [.ticket(.closed("HS-1ABC", status: "deleted"))])
        #expect(deleted.issues.first?.message(in: deleted.bundle) == "HS-1ABC is deleted. Choose an open ticket.")
        #expect(!deleted.canSubmit && deleted.existingTicket == nil)
    }

    @Test func destinationEventsFollowThePhaseRules() {
        typealias Phase = ReviewSessionTests.PhaseName
        for phase in Phase.allCases {
            let editable = phase == .editing || phase == .failed
            var session = ReviewSessionTests.session(in: phase)
            let before = session
            let query = TicketQuery(reference: "HS-1ABC", storePath: "/p.hs2") // ReviewSessionTests.ready's store
            do {
                let applied = session.setDestination(.existingTicket)
                #expect(applied == editable, "\(phase)")
            }
            do {
                let applied = session.editTicket("HS-1ABC")
                #expect(applied == editable, "\(phase)")
            }
            do {
                let applied = session.resolveLookup(query, .success(Self.ticket1))
                #expect(applied == editable, "\(phase)")
            }
            do {
                let applied = session.setTarget(Self.storeB)
                #expect(applied == editable, "\(phase)")
            }
            if !editable { #expect(session == before, "\(phase) changed a frozen session") }
        }
    }

    @Test func switchingBackAndForthKeepsTheTypedTicketAndItsLookup() {
        var session = Self.session()
        #expect(session.destination == .newTicket && session.canSubmit && session.issues.isEmpty)
        session.setDestination(.existingTicket)
        #expect(!session.canSubmit && session.issues == [.ticket(.empty)])
        session.editTicket("HS-1ABC")
        session.resolveLookup(Self.query1, .success(Self.ticket1))
        #expect(session.canSubmit)

        session.setDestination(.newTicket)
        #expect(session.canSubmit && session.existingTicket == nil && session.pendingLookup == nil)
        #expect(session.ticketInput == "HS-1ABC")
        // Back again: no second lookup, the ticket is still confirmed.
        session.setDestination(.existingTicket)
        #expect(session.pendingLookup == nil && session.existingTicket == Self.ticket1)

        // A new ticket's submit starts by creating it; an existing ticket's by attaching.
        var existing = session
        existing.beginSubmit()
        #expect(existing.phase == .submitting(.attachingMedia))
        session.setDestination(.newTicket)
        session.beginSubmit()
        #expect(session.phase == .submitting(.creatingTicket))
    }

    @Test func aResultForASlugEditedMeanwhileIsIgnored() {
        var session = Self.session()
        session.setDestination(.existingTicket)
        session.editTicket("HS-1ABC")
        session.editTicket("HS-2XYZ")
        do {
            let applied = session.resolveLookup(Self.query1, .success(Self.ticket1))
            #expect(!applied)
        }
        #expect(Self.name(session.ticketLookup) == "looking(HS-2XYZ@/a.hs2)")
        let query2 = TicketQuery(reference: "HS-2XYZ", storePath: "/a.hs2")
        do {
            let applied = session.resolveLookup(query2, .success(nil))
            #expect(applied)
        }
        // A repeated result is ignored too.
        do {
            let applied = session.resolveLookup(query2, .success(Self.ticket1))
            #expect(!applied)
        }
        #expect(session.issues == [.ticket(.notFound("HS-2XYZ", store: "/a.hs2"))])
    }

    @Test func emptiedThenRefilledLooksUpAgain() {
        var session = Self.session(in: .found)
        session.editTicket("")
        #expect(session.issues == [.ticket(.empty)])
        session.editTicket("HS-1ABC")
        #expect(session.pendingLookup == Self.query1 && !session.canSubmit)
        session.resolveLookup(Self.query1, .success(Self.ticket1))
        #expect(session.canSubmit)
    }

    @Test func aProjectChangeLooksTheTicketUpInTheNewStore() {
        var session = Self.session(in: .found)
        session.setTarget(Self.storeB)
        #expect(session.pendingLookup == TicketQuery(reference: "HS-1ABC", storePath: "/b.hs2"))
        // The old store's answer no longer counts.
        do {
            let applied = session.resolveLookup(Self.query1, .success(Self.ticket1))
            #expect(!applied)
        }
        session.setTarget(Self.noStore)
        #expect(session.issues.map { $0.message(in: session.bundle) } == ["No project selected."])
        session.setTarget(Self.storeA)
        #expect(session.pendingLookup == Self.query1)
    }

    @Test func afterAFailureTheTicketCanStillChange() {
        var session = Self.session(in: .found)
        session.beginSubmit()
        session.finish(.failure(SubmissionFailure(message: "note failed", attachedTo: "HS-1ABC")))
        do {
            let applied = session.editTicket("HS-2XYZ")
            #expect(applied)
        }
        #expect(session.pendingLookup?.reference == "HS-2XYZ")
        #expect(!session.canSubmit)
    }
}

/// `DraftSubmitter` adding a draft to an existing ticket (docs/07 §7.5): the attach batch, the note
/// citing stored names, clean-up, and resume after a failed note without a second batch or note.
struct ExistingTicketSubmitterTests {
    static let existing = HotSheetTicket(
        id: "01M4CCW6AW9EHFYT2QTZJ70H8D", slug: "HS-OLD001", title: "Accounts page", status: "started", file: "/stores/a.hs2/t.md"
    )

    @Test func attachesThenAddsANoteAndDeletesTheDraft() throws {
        let fixture = try DraftSubmitterTests.Fixture()
        let draft = try fixture.draft(captures: 2)
        fixture.client.existingNames = ["review.json"] // the ticket already has a review.json
        var steps: [SubmitStep] = []
        let result = try fixture.submitter().submit(draft.directory, title: " Follow-up ", summary: "More notes", into: Self.existing) {
            steps.append($0)
        }
        #expect(steps == [.attachingMedia, .addingNote])
        #expect(result == SubmittedReview(
            ticket: CreatedTicket(slug: "HS-OLD001", file: "/stores/a.hs2/t.md"), title: "Follow-up", mediaCount: 2, annotationCount: 2,
            storePath: "/stores/a.hs2", submittedAt: Date(timeIntervalSince1970: 5000), draftRemoved: true,
            addedToExistingTicket: true, ticketTitle: "Accounts page"
        ))
        #expect(fixture.client.created.isEmpty)
        let batch = try #require(fixture.client.attached.first)
        #expect(fixture.client.attached.count == 1)
        #expect(batch.slug == "HS-OLD001" && batch.label == "UX review capture" && batch.purpose == "problem_evidence")
        #expect(batch.files.map(\.lastPathComponent) == ["capture-1.png", "capture-2.mov", "review.json"])
        let note = try #require(fixture.client.notes.first)
        #expect(fixture.client.notes.count == 1 && note.slug == "HS-OLD001")
        #expect(note.markdown.hasPrefix("## UX review: Follow-up\n"))
        #expect(note.markdown.contains("More notes"))
        #expect(note.markdown.contains("`attachment:review (2).json` is the canonical"))
        #expect(note.markdown.contains("#### #2 · comment · `attachment:capture-2.mov`"))
        #expect(!fixture.exists(draft.directory))
    }

    @Test func aFailedNoteKeepsTheDraftAndTheRetryAddsOnlyTheNote() throws {
        let fixture = try DraftSubmitterTests.Fixture()
        let draft = try fixture.draft(captures: 2)
        fixture.client.existingNames = ["capture-1.png"]
        fixture.client.noteErrors = [
            HotSheetError.commandFailed(command: "edit", exitCode: 1, stderr: "locked"),
            HotSheetError.commandFailed(command: "edit", exitCode: 1, stderr: "still locked"),
        ]
        #expect(throws: SubmissionFailure(
            message: "The media was attached to HS-OLD001, but adding the review note failed: hotsheet-cli edit failed (exit 1): locked",
            attachedTo: "HS-OLD001"
        )) { try fixture.submitter().submit(draft.directory, into: Self.existing) }
        #expect(fixture.exists(draft.directory))
        let pending = try #require(fixture.store.pendingSubmission(in: draft.directory))
        #expect(pending == PendingSubmission(
            storePath: "/stores/a.hs2", ticket: Self.existing.createdTicket, createdAt: Date(timeIntervalSince1970: 5000),
            attachedNames: ["capture-1.png": "capture-1 (2).png", "capture-2.mov": "capture-2.mov", "review.json": "review.json"]
        ))
        #expect(try fixture.store.listDrafts().first?.pendingNoteOnly == true)

        // Second failure: still one batch; the record unchanged.
        var steps: [SubmitStep] = []
        #expect(throws: SubmissionFailure.self) {
            try fixture.submitter().submit(draft.directory, into: Self.existing) { steps.append($0) }
        }
        #expect(steps == [.addingNote])
        #expect(fixture.client.attached.count == 1)
        #expect(fixture.store.pendingSubmission(in: draft.directory) == pending)

        let result = try fixture.submitter().submit(draft.directory, into: Self.existing)
        #expect(result.addedToExistingTicket && result.ticket.slug == "HS-OLD001")
        #expect(fixture.client.attached.count == 1)
        #expect(fixture.client.notes.count == 1)
        // The note cites the name the first attach stored.
        #expect(fixture.client.notes.first?.markdown.contains("#### #1 · comment · `attachment:capture-1 (2).png`") == true)
        #expect(!fixture.exists(draft.directory))
    }

    @Test func aFailedAttachWritesNoRecordAndTheRetryStartsOver() throws {
        let fixture = try DraftSubmitterTests.Fixture()
        let draft = try fixture.draft(captures: 1)
        fixture.client.attachErrors = [HotSheetError.commandFailed(
            command: "attach",
            exitCode: 1,
            stderr: "no ticket matching 'HS-OLD001'"
        )]
        #expect(throws: SubmissionFailure(message: "hotsheet-cli attach failed (exit 1): no ticket matching 'HS-OLD001'")) {
            try fixture.submitter().submit(draft.directory, into: Self.existing)
        }
        #expect(fixture.store.pendingSubmission(in: draft.directory) == nil)
        #expect(fixture.client.notes.isEmpty)
        _ = try fixture.submitter().submit(draft.directory, into: Self.existing)
        #expect(fixture.client.attached.count == 1 && fixture.client.notes.count == 1)
    }

    @Test func recordsAreOnlyReusedForTheSameKindTicketAndStore() throws {
        // A note-pending record for another ticket: the new target gets its own attach + note.
        let fixture = try DraftSubmitterTests.Fixture()
        let draft = try fixture.draft(captures: 1)
        let names = ["capture-1.png": "capture-1.png", "review.json": "review.json"]
        try fixture.store.savePendingSubmission(
            PendingSubmission(
                storePath: "/stores/a.hs2",
                ticket: CreatedTicket(slug: "HS-OTHER1"),
                createdAt: .distantPast,
                attachedNames: names
            ),
            in: draft.directory
        )
        var other = Self.existing
        other.slug = "HS-OLD002"
        _ = try fixture.submitter().submit(draft.directory, into: other)
        #expect(fixture.client.attached.map(\.slug) == ["HS-OLD002"] && fixture.client.notes.map(\.slug) == ["HS-OLD002"])

        // A note-pending record is not a created ticket: filing as new creates one.
        let second = try DraftSubmitterTests.Fixture()
        let draft2 = try second.draft(captures: 1)
        try second.store.savePendingSubmission(
            PendingSubmission(
                storePath: "/stores/a.hs2",
                ticket: Self.existing.createdTicket,
                createdAt: .distantPast,
                attachedNames: names
            ),
            in: draft2.directory
        )
        let filed = try second.submitter().submit(draft2.directory)
        #expect(filed.ticket.slug == "HS-TEST01" && !filed.addedToExistingTicket && second.client.created.count == 1)

        // A created-ticket record is not reused when adding to an existing ticket.
        let third = try DraftSubmitterTests.Fixture()
        let draft3 = try third.draft(captures: 1)
        try third.store.savePendingSubmission(
            PendingSubmission(storePath: "/stores/a.hs2", ticket: CreatedTicket(slug: "HS-TEST09"), createdAt: .distantPast),
            in: draft3.directory
        )
        _ = try third.submitter().submit(draft3.directory, into: Self.existing)
        #expect(third.client.attached.map(\.slug) == ["HS-OLD001"] && third.client.created.isEmpty)

        // A note-pending record in another store is ignored.
        let fourth = try DraftSubmitterTests.Fixture()
        let draft4 = try fourth.draft(captures: 1)
        try fourth.store.savePendingSubmission(
            PendingSubmission(
                storePath: "/stores/b.hs2",
                ticket: Self.existing.createdTicket,
                createdAt: .distantPast,
                attachedNames: names
            ),
            in: draft4.directory
        )
        _ = try fourth.submitter().submit(draft4.directory, into: Self.existing)
        #expect(fourth.client.attached.count == 1)
    }

    @Test func invalidOrIncompleteDraftsWriteNothing() throws {
        let fixture = try DraftSubmitterTests.Fixture()
        let draft = try fixture.draft(captures: 2)
        try FileManager.default.removeItem(at: draft.directory.appendingPathComponent("capture-2.mov"))
        #expect(throws: SubmissionFailure(message: "capture-2.mov is missing from the review.")) {
            try fixture.submitter().submit(draft.directory, into: Self.existing)
        }
        #expect(fixture.client.attached.isEmpty && fixture.client.notes.isEmpty)
    }

    @Test func pendingRecordsWithoutNamesStillDecode() throws {
        let json = #"{"storePath":"/s.hs2","ticket":{"slug":"HS-1"},"createdAt":"2026-10-07T00:00:00Z"}"#
        let record = try ReviewBundle.makeDecoder().decode(PendingSubmission.self, from: Data(json.utf8))
        #expect(record.attachedNames == nil && !record.isAddedToExistingTicket)
    }
}
