import Foundation

/// Something that keeps a review from being submitted, shown inline in the session window.
/// Spec: docs/07-review-session.md §7.3.
public enum SessionIssue: Equatable, Sendable {
    case noCaptures
    case blankTitle
    /// A capture's file is gone from the draft directory.
    case missingFile(mediaId: String, filename: String)
    /// Hot Sheet can't take the review (no CLI, no project, no store).
    case hotSheet(String)
    /// A `ReviewBundle.validate()` rule, with the bundle it came from for readable messages.
    case bundle(BundleIssue)
    /// Adding to an existing ticket: it isn't entered, recognized, found, or open (yet).
    case ticket(TicketIssue)

    /// The capture this issue is about, when there is one (the list marks it).
    public func mediaId(in bundle: ReviewBundle) -> String? {
        switch self {
        case let .missingFile(mediaId, _): mediaId
        case let .bundle(issue):
            switch issue {
            case let .duplicateMediaId(id), let .invalidMediaSize(id): id
            case let .duplicateFilename(name): bundle.media.first { $0.filename == name }?.id
            case let .unknownMedia(annotationId, _), let .shapeOutOfBounds(annotationId), let .tooFewPoints(annotationId, _),
                 let .invalidTimeRange(annotationId), let .timeRangeOnImage(annotationId), let .timeRangeBeyondDuration(annotationId):
                bundle.annotations.first { $0.id == annotationId }?.mediaId
            case .unsupportedSchema, .noMedia, .duplicateAnnotationId: nil
            }
        case .noCaptures, .blankTitle, .hotSheet, .ticket: nil
        }
    }

    /// One readable sentence. Annotations are named by their review number (`#N`), as in the
    /// editor and the ticket.
    public func message(in bundle: ReviewBundle) -> String {
        switch self {
        case .noCaptures: "Add at least one capture."
        case .blankTitle: "Give the review a title."
        case let .missingFile(_, filename): "\(filename) is missing from the draft folder. Remove it from the review."
        case let .hotSheet(problem): problem
        case let .bundle(issue): Self.message(for: issue, in: bundle)
        case let .ticket(issue): issue.message
        }
    }

    private static func message(for issue: BundleIssue, in bundle: ReviewBundle) -> String {
        func annotation(_ id: String) -> String {
            bundle.annotations.firstIndex { $0.id == id }.map { "Annotation #\($0 + 1)" } ?? "Annotation \(id)"
        }
        func media(_ id: String) -> String {
            bundle.media.first { $0.id == id }?.filename ?? id
        }
        return switch issue {
        case let .unsupportedSchema(schema): "This review uses an unsupported format (\(schema))."
        case .noMedia: "Add at least one capture."
        case let .duplicateMediaId(id): "Two captures share the id \(id)."
        case let .duplicateFilename(name): "Two captures share the file name \(name)."
        case let .invalidMediaSize(id): "\(media(id)) has no pixel size."
        case let .duplicateAnnotationId(id): "Two annotations share the id \(id)."
        case let .unknownMedia(id, _): "\(annotation(id)) is on a capture that is no longer in the review."
        case let .shapeOutOfBounds(id): "\(annotation(id)) lies outside its capture."
        case let .tooFewPoints(id, minimum): "\(annotation(id)) needs at least \(minimum) points."
        case let .invalidTimeRange(id): "\(annotation(id)) ends before it starts."
        case let .timeRangeOnImage(id): "\(annotation(id)) has a time range, but its capture is a still image."
        case let .timeRangeBeyondDuration(id): "\(annotation(id)) runs past the end of its video."
        }
    }

    /// Every issue for `bundle`, in a stable order: session-level ones first, then the bundle's
    /// own validation (without its duplicate "no media" rule).
    public static func all(
        for bundle: ReviewBundle,
        target: HotSheetStatus,
        fileExists: (MediaItem) -> Bool
    ) -> [SessionIssue] {
        var issues: [SessionIssue] = []
        if bundle.media.isEmpty { issues.append(.noCaptures) }
        if bundle.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.blankTitle) }
        for item in bundle.media where !fileExists(item) {
            issues.append(.missingFile(mediaId: item.id, filename: item.filename))
        }
        issues += bundle.validate().filter { $0 != .noMedia }.map(SessionIssue.bundle)
        if let problem = target.problem { issues.append(.hotSheet(problem)) }
        return issues
    }
}

/// A review filed in Hot Sheet.
public struct SubmittedReview: Codable, Equatable, Sendable {
    public var ticket: CreatedTicket
    public var title: String
    public var mediaCount: Int
    public var annotationCount: Int
    public var storePath: String
    public var submittedAt: Date
    /// False when the draft folder could not be deleted after filing (it is no longer current,
    /// so it never receives captures again).
    public var draftRemoved: Bool
    /// The review went into an existing ticket as a note, rather than a new intake ticket.
    public var addedToExistingTicket: Bool
    /// The existing ticket's own title (when `addedToExistingTicket`).
    public var ticketTitle: String?
    /// Only part of the review went to the existing ticket: the draft is kept with this many
    /// captures that weren't sent (§7.2.2). Nil when the whole review was filed.
    public var remainingCaptures: Int?

    public init(
        ticket: CreatedTicket,
        title: String,
        mediaCount: Int,
        annotationCount: Int,
        storePath: String,
        submittedAt: Date,
        draftRemoved: Bool = true,
        addedToExistingTicket: Bool = false,
        ticketTitle: String? = nil,
        remainingCaptures: Int? = nil
    ) {
        self.ticket = ticket
        self.title = title
        self.mediaCount = mediaCount
        self.annotationCount = annotationCount
        self.storePath = storePath
        self.submittedAt = submittedAt
        self.draftRemoved = draftRemoved
        self.addedToExistingTicket = addedToExistingTicket
        self.ticketTitle = ticketTitle
        self.remainingCaptures = remainingCaptures
    }
}

/// Why a submission stopped. The session stays editable and can try again.
public struct SubmissionFailure: Error, Equatable, Sendable {
    public var message: String
    /// Set when a ticket was created but its attachments were not: the retry attaches to it.
    public var createdTicket: String?
    /// Set when the media was attached to an existing ticket but the note was not: the retry adds
    /// only the note. With `partlyAttached`, only some of the media is attached there.
    public var attachedTo: String?
    /// Some files were attached before the attach failed: the retry attaches only the rest.
    public var partlyAttached: Bool

    public init(message: String, createdTicket: String? = nil, attachedTo: String? = nil, partlyAttached: Bool = false) {
        self.message = message
        self.createdTicket = createdTicket
        self.attachedTo = attachedTo
        self.partlyAttached = partlyAttached
    }
}

/// The review session's state: a draft being finished in the session window, then filed in
/// Hot Sheet. Pure (no files, no UI); the window and `--submit` drive it.
///
/// ```
/// editing ⇄ failed            (edits, removals, refreshes, target and destination changes allowed)
/// editing|failed → submitting(creatingTicket → attachingMedia) → submitted   (terminal)
///                  submitting(attachingMedia → addingNote)     ↘ failed      (existing ticket)
/// ```
/// Events that don't apply to the current phase are ignored and return false: a second
/// submit while submitting, edits during or after submission, a result with no submission
/// running. The destination (a new ticket, or an existing one being looked up) is in
/// `ReviewSession+Destination.swift`. Spec: docs/07-review-session.md §7.4.
public struct ReviewSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case editing
        case submitting(SubmitStep)
        case submitted(SubmittedReview)
        case failed(SubmissionFailure)
    }

    public let directory: URL
    public private(set) var bundle: ReviewBundle
    public private(set) var phase: Phase = .editing
    public private(set) var target: HotSheetStatus
    /// Filenames of captures whose files are missing on disk.
    public private(set) var missingFiles: Set<String>
    /// Where the review goes: a new intake ticket (the default) or an existing ticket.
    public internal(set) var destination: ReviewDestination = .newTicket
    /// What the reviewer typed into the existing-ticket field (kept while on New ticket).
    public internal(set) var ticketInput = ""
    /// The existing ticket's lookup, for `ticketInput` in the target's store.
    public internal(set) var ticketLookup: TicketLookup = .empty
    /// What goes to an existing ticket (everything by default; ignored for a new ticket).
    public internal(set) var selection = ReviewSelection()

    public init(directory: URL, bundle: ReviewBundle, target: HotSheetStatus, missingFiles: Set<String> = []) {
        self.directory = directory
        self.bundle = bundle
        self.target = target
        self.missingFiles = missingFiles
    }

    /// Editing is possible before submitting and after a failure.
    public var isEditable: Bool {
        switch phase {
        case .editing, .failed: true
        case .submitting, .submitted: false
        }
    }

    public var isSubmitting: Bool {
        if case .submitting = phase { true } else { false }
    }

    public var issues: [SessionIssue] {
        SessionIssue.all(for: bundle, target: target) { !missingFiles.contains($0.filename) } + destinationIssues
    }

    public var canSubmit: Bool { isEditable && issues.isEmpty }

    /// Annotations on one capture (for the capture list).
    public func annotationCount(_ mediaId: String) -> Int {
        bundle.annotations.reduce(0) { $0 + ($1.mediaId == mediaId ? 1 : 0) }
    }

    /// Takes the draft as it is on disk now (captures added or removed, editor saves), keeping
    /// the title and summary being typed.
    @discardableResult
    public mutating func refresh(_ disk: ReviewBundle, missingFiles: Set<String>) -> Bool {
        guard isEditable else { return false }
        var next = disk
        next.title = bundle.title
        next.summary = bundle.summary
        bundle = next
        self.missingFiles = missingFiles
        selection = selection.pruned(to: next)
        return true
    }

    @discardableResult
    public mutating func edit(title: String? = nil, summary: String? = nil) -> Bool {
        guard isEditable else { return false }
        if let title { bundle.title = title }
        if let summary { bundle.summary = summary }
        return true
    }

    @discardableResult
    public mutating func setTarget(_ status: HotSheetStatus) -> Bool {
        guard isEditable else { return false }
        target = status
        // Another store (or none) means the ticket has to be looked up again.
        updateLookup()
        return true
    }

    /// Starts a submission. False (and nothing changes) unless editable and free of issues.
    @discardableResult
    public mutating func beginSubmit() -> Bool {
        guard canSubmit else { return false }
        phase = .submitting(destination == .newTicket ? .creatingTicket : .attachingMedia)
        return true
    }

    @discardableResult
    public mutating func advance(_ step: SubmitStep) -> Bool {
        guard isSubmitting else { return false }
        phase = .submitting(step)
        return true
    }

    @discardableResult
    public mutating func finish(_ result: Result<SubmittedReview, SubmissionFailure>) -> Bool {
        guard isSubmitting else { return false }
        switch result {
        case let .success(review): phase = .submitted(review)
        case let .failure(failure): phase = .failed(failure)
        }
        return true
    }
}

/// Files a draft in Hot Sheet and cleans up after it: re-reads the draft from disk, submits it
/// (resuming a ticket whose attach failed earlier), and deletes the draft once the ticket has its
/// media. On failure the draft is kept, plus `submission.json` when the ticket already exists.
/// Spec: docs/07-review-session.md §7.5.
public struct DraftSubmitter: Sendable {
    public var store: ReviewDraftStore
    public var client: HotSheetClient
    public var storePath: URL
    public var now: @Sendable () -> Date
    /// The id of a new attach batch (`ReviewSubmitter.makeBatchID`).
    public var makeBatchID: @Sendable () -> String

    public init(
        store: ReviewDraftStore,
        client: HotSheetClient,
        storePath: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        makeBatchID: @escaping @Sendable () -> String = ReviewSubmitter.newBatchID
    ) {
        self.store = store
        self.client = client
        self.storePath = storePath
        self.now = now
        self.makeBatchID = makeBatchID
    }

    /// - Parameters:
    ///   - title, summary: the session's fields, saved into the draft first (title trimmed).
    ///   - existing: add the review to this ticket (attach, then a note) instead of filing a new one.
    ///   - selection: with `existing`, only these captures and annotations (§7.2.2). What isn't
    ///     sent stays in the draft.
    public func submit(
        _ directory: URL,
        title: String? = nil,
        summary: String? = nil,
        into existing: HotSheetTicket? = nil,
        selection: ReviewSelection = ReviewSelection(),
        progress: (SubmitStep) -> Void = { _ in }
    ) throws(SubmissionFailure) -> SubmittedReview {
        let draft: ReviewDraft
        do {
            draft = try store.update(directory) { bundle in
                bundle.title = (title ?? bundle.title).trimmingCharacters(in: .whitespacesAndNewlines)
                if let summary { bundle.summary = summary }
            }
        } catch {
            throw SubmissionFailure(message: ReviewSubmitter.describe(error))
        }
        let pending = store.pendingSubmission(in: directory).flatMap { $0.storePath == storePath.path ? $0 : nil }
        // Part of the review goes only to an existing ticket; a resumed record keeps its part (§7.2.2).
        let part = existing.map { Self.selection(selection, resuming: pending, for: $0, in: draft.bundle) } ?? ReviewSelection()
        // Crops and trims are applied only now (HS2-71SSJG).
        let staged: SubmissionStaging
        do {
            try store.migrateLegacyEdits(directory)
            staged = try SubmissionStaging.prepare(store.load(directory), selection: part)
        } catch {
            throw SubmissionFailure(message: "Couldn't prepare the cropped or trimmed media: \(ReviewSubmitter.describe(error))")
        }
        defer { staged.cleanUp() }
        if let existing {
            return try add(draft, staged: staged, to: existing, pending: pending, progress: progress)
        }
        // A record left by adding to an existing ticket is not a created ticket to reuse.
        let resumable = pending.flatMap { $0.isForExistingTicket ? nil : $0 }
        let ticket: CreatedTicket
        do {
            ticket = try ReviewSubmitter(client: client, makeBatchID: makeBatchID).file(
                staged.bundle,
                mediaDirectory: staged.mediaDirectory,
                existingTicket: resumable?.ticket,
                resume: resumable?.partialAttach,
                progress: progress
            )
        } catch let ReviewSubmissionError.attachFailed(created, reason, partial) {
            try? store.savePendingSubmission(
                PendingSubmission(
                    storePath: storePath.path, ticket: created, createdAt: resumable?.createdAt ?? now(), partialAttach: partial
                ),
                in: directory
            )
            throw SubmissionFailure(
                message: "\(created.slug) was created, but attaching the media failed: \(reason)",
                createdTicket: created.slug,
                partlyAttached: partial != nil
            )
        } catch {
            throw SubmissionFailure(message: ReviewSubmitter.describe(error), createdTicket: resumable?.ticket.slug)
        }
        let removed = (try? store.removeSubmitted(directory)) != nil
        return SubmittedReview(
            ticket: ticket,
            title: draft.bundle.title,
            mediaCount: staged.bundle.media.count,
            annotationCount: staged.bundle.annotations.count,
            storePath: storePath.path,
            submittedAt: now(),
            draftRemoved: removed
        )
    }
}
