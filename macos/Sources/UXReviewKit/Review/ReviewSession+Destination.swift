import Foundation

/// Where a review goes. Spec: docs/07-review-session.md §7.2.1.
public enum ReviewDestination: String, Codable, Equatable, Sendable {
    /// A new intake ticket that an AI splits into one ticket per change (the default).
    case newTicket
    /// A note plus attachments on a ticket that already exists.
    case existingTicket
}

/// One lookup of a ticket reference in one store. A result only applies while the session still
/// waits for the same query, so a slug edited or a project changed meanwhile drops it.
public struct TicketQuery: Equatable, Sendable {
    /// The slug or ULID `TicketReference.parse` found.
    public var reference: String
    public var storePath: String

    public init(reference: String, storePath: String) {
        self.reference = reference
        self.storePath = storePath
    }

    /// Runs the lookup with `hotsheet-cli show` (blocking; call it off the main thread).
    public func run(cliPath: String, runner: ProcessRunning = SystemProcessRunner()) -> Result<HotSheetTicket?, SubmissionFailure> {
        let client = HotSheetCLIClient(
            executable: URL(fileURLWithPath: cliPath),
            storePath: URL(fileURLWithPath: storePath),
            runner: runner
        )
        do {
            return try .success(client.findTicket(reference))
        } catch {
            return .failure(SubmissionFailure(message: ReviewSubmitter.describe(error)))
        }
    }
}

/// The existing-ticket field's state.
public enum TicketLookup: Equatable, Sendable {
    /// Nothing typed.
    case empty
    /// Typed text with no slug or ULID in it.
    case unrecognized(String)
    /// A reference, but no store to look in (the Hot Sheet project problem covers it).
    case noStore(String)
    case looking(TicketQuery)
    case found(TicketQuery, HotSheetTicket)
    case notFound(TicketQuery)
    case failed(TicketQuery, String)

    /// The query this state is about, when there is one.
    public var query: TicketQuery? {
        switch self {
        case let .looking(query), let .found(query, _), let .notFound(query), let .failed(query, _): query
        case .empty, .unrecognized, .noStore: nil
        }
    }
}

/// Why the existing-ticket destination can't take the review (yet).
public enum TicketIssue: Equatable, Sendable {
    case empty
    case unrecognized(String)
    case looking(String)
    case notFound(String, store: String)
    case closed(String, status: String)
    case lookupFailed(String, reason: String)
    /// Every capture is left out of what goes to the ticket (§7.2.2).
    case nothingSelected

    public var message: String {
        switch self {
        case .empty:
            "Enter the ticket to add this review to."
        case let .unrecognized(text):
            "“\(Self.clip(text))” isn't a ticket. Enter a slug such as HS-ABC123."
        case let .looking(reference):
            "Looking up \(reference)…"
        case let .notFound(reference, store):
            "No ticket \(reference) in \((store as NSString).lastPathComponent)."
        case let .closed(slug, status):
            "\(slug) is \(status.replacingOccurrences(of: "_", with: " ")). Choose an open ticket."
        case let .lookupFailed(reference, reason):
            "Couldn't look up \(reference): \(reason)"
        case .nothingSelected:
            "Choose at least one capture to add."
        }
    }

    private static func clip(_ text: String) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return flat.count > 40 ? flat.prefix(39) + "…" : flat
    }
}

/// The destination half of the session state machine (docs/07 §7.4): the destination, the typed
/// ticket reference, and its lookup. Like every edit, these apply only while editable.
///
/// ```
/// empty ⇄ unrecognized ⇄ looking(q) → found(q) | notFound(q) | failed(q)
///                        ↖ noStore (no store to look in)
/// ```
/// Typing, switching the project, or switching back to an existing ticket recomputes the state.
/// A reference that parses to the query already looked up (or being looked up) keeps its state.
public extension ReviewSession {
    /// The ticket the review would be added to: found, open, and the existing destination chosen.
    var existingTicket: HotSheetTicket? {
        guard destination == .existingTicket, case let .found(_, ticket) = ticketLookup, ticket.acceptsReviews else { return nil }
        return ticket
    }

    /// The lookup to run now, if any (only while the existing destination is chosen).
    var pendingLookup: TicketQuery? {
        guard destination == .existingTicket, isEditable, case let .looking(query) = ticketLookup else { return nil }
        return query
    }

    /// What would be sent: the selected part of the review for an existing ticket, else all of it.
    var selectedBundle: ReviewBundle {
        destination == .existingTicket ? selection.apply(to: bundle) : bundle
    }

    /// Sets what goes to an existing ticket (ids no longer in the review are dropped).
    @discardableResult
    mutating func setSelection(_ selection: ReviewSelection) -> Bool {
        guard isEditable else { return false }
        self.selection = selection.pruned(to: bundle)
        return true
    }

    @discardableResult
    mutating func setDestination(_ destination: ReviewDestination) -> Bool {
        guard isEditable else { return false }
        self.destination = destination
        updateLookup()
        return true
    }

    /// The text in the existing-ticket field.
    @discardableResult
    mutating func editTicket(_ text: String) -> Bool {
        guard isEditable else { return false }
        ticketInput = text
        updateLookup()
        return true
    }

    /// Applies a lookup result. Ignored (false) unless the session still waits for `query`.
    /// - Parameter result: the ticket, nil for "no such ticket", or why the lookup failed.
    @discardableResult
    mutating func resolveLookup(_ query: TicketQuery, _ result: Result<HotSheetTicket?, SubmissionFailure>) -> Bool {
        guard isEditable, ticketLookup == .looking(query) else { return false }
        switch result {
        case let .success(ticket?): ticketLookup = .found(query, ticket)
        case .success(nil): ticketLookup = .notFound(query)
        case let .failure(failure): ticketLookup = .failed(query, failure.message)
        }
        return true
    }

    /// The destination's issue, when it blocks submitting.
    internal var destinationIssues: [SessionIssue] {
        guard destination == .existingTicket else { return [] }
        let issue: TicketIssue? = switch ticketLookup {
        case .empty: .empty
        case let .unrecognized(text): .unrecognized(text)
        case .noStore: nil // the Hot Sheet project issue already blocks submitting
        case let .looking(query): .looking(query.reference)
        case let .found(_, ticket): ticket.acceptsReviews ? nil : .closed(ticket.slug, status: ticket.status)
        case let .notFound(query): .notFound(query.reference, store: query.storePath)
        case let .failed(query, reason): .lookupFailed(query.reference, reason: reason)
        }
        var issues = issue.map { [SessionIssue.ticket($0)] } ?? []
        if !bundle.media.isEmpty, selection.apply(to: bundle).media.isEmpty { issues.append(.ticket(.nothingSelected)) }
        return issues
    }

    /// Recomputes the lookup state from the typed text and the target's store.
    internal mutating func updateLookup() {
        guard let reference = TicketReference.parse(ticketInput) else {
            let blank = ticketInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ticketLookup = blank ? .empty : .unrecognized(ticketInput)
            return
        }
        guard target.problem == nil, let store = target.storePath else {
            ticketLookup = .noStore(reference)
            return
        }
        let query = TicketQuery(reference: reference, storePath: store)
        if ticketLookup.query == query { return }
        ticketLookup = .looking(query)
    }
}

extension DraftSubmitter {
    /// The record of a half-finished submission to this same existing ticket, if any.
    static func ownRecord(_ pending: PendingSubmission?, for existing: HotSheetTicket) -> PendingSubmission? {
        pending.flatMap { $0.ticket.slug == existing.slug && $0.isForExistingTicket ? $0 : nil }
    }

    /// What goes to `existing`: the part a half-finished submission to it started with, else the
    /// requested part; ids no longer in the draft are dropped.
    static func selection(
        _ requested: ReviewSelection, resuming pending: PendingSubmission?, for existing: HotSheetTicket, in bundle: ReviewBundle
    ) -> ReviewSelection {
        let own = ownRecord(pending, for: existing)
        return (own == nil ? requested : own?.selection ?? ReviewSelection()).pruned(to: bundle)
    }

    /// Adds the draft to an existing ticket (docs/07 §7.5): one attach batch, then the note.
    /// A record for the same ticket whose batch is already attached resumes with the note alone.
    /// `staged` holds only its `selection` (§7.2.2).
    func add(
        _ draft: ReviewDraft,
        staged: SubmissionStaging,
        to existing: HotSheetTicket,
        pending: PendingSubmission?,
        progress: (SubmitStep) -> Void
    ) throws(SubmissionFailure) -> SubmittedReview {
        // Only a record of this same existing ticket is resumed (§7.5).
        let own = Self.ownRecord(pending, for: existing)
        let resume = own?.attachedNames
        let sent = staged.bundle
        guard !sent.media.isEmpty else { throw SubmissionFailure(message: TicketIssue.nothingSelected.message) }
        let record = PendingSubmission(
            storePath: storePath.path, ticket: existing.createdTicket, createdAt: own?.createdAt ?? now(), toExistingTicket: true,
            selection: staged.selection.isEverything ? nil : staged.selection
        )
        let ticket: CreatedTicket
        do {
            // Crops and trims applied (HS2-71SSJG), as for a new ticket.
            let submitter = ReviewSubmitter(
                client: client, makeBatchID: makeBatchID, ticketText: DraftTicketText.load(from: draft.directory)
            )
            ticket = try submitter.add(
                sent,
                mediaDirectory: staged.mediaDirectory,
                to: existing.createdTicket,
                attached: resume,
                resume: resume == nil ? own?.partialAttach : nil,
                progress: progress
            )
        } catch let ReviewSubmissionError.noteFailed(ticket, attached, reason) {
            var noted = record
            noted.attachedNames = attached
            try? store.savePendingSubmission(noted, in: draft.directory)
            throw SubmissionFailure(
                message: "The media was attached to \(ticket.slug), but adding the review note failed: \(reason)",
                attachedTo: ticket.slug
            )
        } catch let ReviewSubmissionError.attachFailed(ticket, reason, attachedPart) {
            // Nothing attached: nothing to record, and Try Again starts over.
            guard let attachedPart else {
                throw SubmissionFailure(message: reason)
            }
            var partly = record
            partly.partialAttach = attachedPart
            try? store.savePendingSubmission(partly, in: draft.directory)
            throw SubmissionFailure(
                message: "Some of the media was attached to \(ticket.slug) before attaching failed: \(reason)",
                attachedTo: ticket.slug,
                partlyAttached: true
            )
        } catch {
            throw SubmissionFailure(message: ReviewSubmitter.describe(error), attachedTo: resume == nil ? nil : existing.slug)
        }
        // A ticket a failed New ticket try created in this store, now left behind (HS2-3SVGZ3).
        let abandoned = pending.flatMap { $0.isForExistingTicket || $0.ticket.slug == existing.slug ? nil : $0.ticket.slug }
        let (removed, remaining) = cleanUp(draft.directory, after: record.selection)
        return SubmittedReview(
            ticket: ticket,
            title: draft.bundle.title,
            mediaCount: sent.media.count,
            annotationCount: sent.annotations.count,
            storePath: storePath.path,
            submittedAt: now(),
            draftRemoved: removed,
            addedToExistingTicket: true,
            ticketTitle: existing.title,
            remainingCaptures: remaining,
            abandonedTicket: abandoned
        )
    }

    /// After adding to an existing ticket: the whole review deletes the draft; part of it leaves
    /// what wasn't sent (or deletes the draft when nothing is left). If that clean-up fails
    /// part-way, the draft is kept as it is rather than deleted whole.
    private func cleanUp(_ directory: URL, after selection: ReviewSelection?) -> (removed: Bool, remaining: Int?) {
        guard let selection else { return ((try? store.removeSubmitted(directory)) != nil, nil) }
        let left = try? store.removeSent(selection, from: directory)
        return (left == 0, left.flatMap { $0 > 0 ? $0 : nil })
    }
}
