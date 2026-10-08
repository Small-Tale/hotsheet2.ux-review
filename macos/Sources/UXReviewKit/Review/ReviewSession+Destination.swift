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
        return issue.map { [.ticket($0)] } ?? []
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
    /// Adds the draft to an existing ticket (docs/07 §7.5): one attach batch, then the note.
    /// A record for the same ticket whose batch is already attached resumes with the note alone.
    func add(
        _ draft: ReviewDraft,
        staged: SubmissionStaging,
        to existing: HotSheetTicket,
        pending: PendingSubmission?,
        progress: (SubmitStep) -> Void
    ) throws(SubmissionFailure) -> SubmittedReview {
        let resume = pending.flatMap { $0.ticket.slug == existing.slug ? $0.attachedNames : nil }
        let ticket: CreatedTicket
        do {
            // Crops and trims applied (HS2-71SSJG), as for a new ticket.
            ticket = try ReviewSubmitter(client: client).add(
                staged.bundle,
                mediaDirectory: staged.mediaDirectory,
                to: existing.createdTicket,
                attached: resume,
                progress: progress
            )
        } catch let ReviewSubmissionError.noteFailed(ticket, attached, reason) {
            try? store.savePendingSubmission(
                PendingSubmission(
                    storePath: storePath.path, ticket: ticket,
                    createdAt: (resume == nil ? nil : pending?.createdAt) ?? now(), attachedNames: attached
                ),
                in: draft.directory
            )
            throw SubmissionFailure(
                message: "The media was attached to \(ticket.slug), but adding the review note failed: \(reason)",
                attachedTo: ticket.slug
            )
        } catch {
            throw SubmissionFailure(message: ReviewSubmitter.describe(error), attachedTo: resume == nil ? nil : existing.slug)
        }
        let removed = (try? store.removeSubmitted(draft.directory)) != nil
        return SubmittedReview(
            ticket: ticket,
            title: draft.bundle.title,
            mediaCount: staged.bundle.media.count,
            annotationCount: staged.bundle.annotations.count,
            storePath: storePath.path,
            submittedAt: now(),
            draftRemoved: removed,
            addedToExistingTicket: true,
            ticketTitle: existing.title
        )
    }
}
