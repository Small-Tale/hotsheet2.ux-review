import Foundation

/// A half-finished submission, kept in `<draft>/submission.json` so a retry finishes it instead of
/// writing anything twice. Spec: docs/07-review-session.md §7.5.
/// - A ticket was created but its attach failed (`attachedNames` nil): the retry attaches to it
///   instead of creating a second ticket.
/// - The review was being added to an existing ticket, its media is attached, but the note failed
///   (`attachedNames` set): the retry adds only the note.
/// - Either way, an attach that failed part-way (`partialAttach`): the retry attaches only the
///   files it didn't get to, into the same batch (`HS2-QNWMKF`).
public struct PendingSubmission: Codable, Equatable, Sendable {
    /// The store the ticket is in. A retry into a different store starts over.
    public var storePath: String
    public var ticket: CreatedTicket
    public var createdAt: Date
    /// Adding to an existing ticket: the batch already attached, draft file name → stored name.
    public var attachedNames: [String: String]?
    /// The files an interrupted attach got in, and their batch id.
    public var partialAttach: PartialAttach?
    /// The review was being added to `ticket`, an existing ticket (not one this draft created).
    /// Records from before this field mark it with `attachedNames` alone.
    public var toExistingTicket: Bool?
    /// Only part of the review was being added (§7.2.2); a retry sends the same part.
    public var selection: ReviewSelection?

    public init(
        storePath: String,
        ticket: CreatedTicket,
        createdAt: Date,
        attachedNames: [String: String]? = nil,
        partialAttach: PartialAttach? = nil,
        toExistingTicket: Bool? = nil,
        selection: ReviewSelection? = nil
    ) {
        self.storePath = storePath
        self.ticket = ticket
        self.createdAt = createdAt
        self.attachedNames = attachedNames
        self.partialAttach = partialAttach
        self.toExistingTicket = toExistingTicket
        self.selection = selection
    }

    /// The record belongs to adding the review to an existing ticket, so it is never a created
    /// ticket to reuse.
    public var isForExistingTicket: Bool { toExistingTicket == true || attachedNames != nil }

    /// The existing ticket has the whole batch; only the review note is missing.
    public var isNotePending: Bool { attachedNames != nil }

    /// Some, not all, of the review's files are attached.
    public var isPartlyAttached: Bool { attachedNames == nil && partialAttach != nil }
}

/// What the review session (docs/07-review-session.md) does to a draft on disk: edit its title
/// and summary, remove a capture, remember a half-finished submission, and delete the draft once
/// its ticket is filed. Every change runs under the store's lock, like captures and editor saves.
public extension ReviewDraftStore {
    static let pendingSubmissionFilename = "submission.json"

    /// Saves the review's title and summary, keeping everything else on disk as it is.
    @discardableResult
    func setDetails(_ directory: URL, title: String, summary: String) throws -> ReviewDraft {
        try update(directory) { bundle in
            bundle.title = title
            bundle.summary = summary
        }
    }

    /// Removes one capture: its media item, every annotation on it, its file, and its kept
    /// crop or trim (`edits.json`), and any original an older draft kept (`originals/<file>` plus its record). Nothing changes when
    /// `mediaId`
    /// is unknown or review.json can't be written; leftover files are removed best effort.
    @discardableResult
    func removeMedia(_ mediaId: String, from directory: URL) throws -> ReviewDraft {
        lock.lock()
        defer { lock.unlock() }
        var draft = try read(directory)
        guard let item = draft.bundle.media.first(where: { $0.id == mediaId }) else {
            throw ReviewDraftError.unknownMedia(mediaId)
        }
        // Remember the highest number used, so the next capture never reuses this one's file
        // name or id (docs/07 §7.2). Written first: a stale record only skips numbers.
        var numbering = DraftNumbering.load(from: directory)
        numbering.record(draft.bundle.media)
        try numbering.save(to: directory)
        draft.bundle.media.removeAll { $0.id == mediaId }
        draft.bundle.annotations.removeAll { $0.mediaId == mediaId }
        try write(draft.bundle, to: draft.bundleURL)

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: draft.mediaURL(item))
        let originals = directory.appendingPathComponent(EditorSession.originalsDirectory, isDirectory: true)
        let original = originals.appendingPathComponent(item.filename)
        if fileManager.fileExists(atPath: original.path) { try? fileManager.removeItem(at: original) }
        var edits = DraftEdits.load(from: directory)
        if edits.crops[item.filename] != nil || edits.trims[item.filename] != nil {
            edits.crops[item.filename] = nil
            edits.trims[item.filename] = nil
            try? edits.save(to: directory)
        }
        var index = OriginalsIndex.load(from: originals)
        if index.crops[item.filename] != nil || index.trims[item.filename] != nil {
            index.crops[item.filename] = nil
            index.trims[item.filename] = nil
            try? index.save(to: originals)
        }
        return draft
    }

    /// After part of the review went to an existing ticket (§7.2.2): removes every annotation the
    /// selection sent, then every capture it sent that has no annotations left, and the
    /// submission record. Returns how many captures remain; when none do, the draft is deleted
    /// like a submitted one and the result is 0.
    func removeSent(_ selection: ReviewSelection, from directory: URL) throws -> Int {
        // First, so a retry after a failed clean-up never sends the same part (or note) again.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.pendingSubmissionFilename))
        let draft = try update(directory) { bundle in
            bundle.annotations.removeAll(where: selection.includes)
        }
        let kept = Set(draft.bundle.annotations.map(\.mediaId))
        for item in draft.bundle.media where selection.includes(media: item.id) && !kept.contains(item.id) {
            try removeMedia(item.id, from: directory)
        }
        let left = try load(directory).bundle.media.count
        guard left > 0 else {
            try removeSubmitted(directory)
            return 0
        }
        return left
    }

    /// Saves the reviewer's edited preamble for `mode` (docs/07 §7.2.3); nil, or the standard
    /// text, goes back to the standard one.
    @discardableResult
    func setTicketText(_ template: String?, for mode: TicketPreamble.Mode, in directory: URL) throws -> DraftTicketText {
        lock.lock()
        defer { lock.unlock() }
        var text = DraftTicketText.load(from: directory)
        text[mode] = template
        try text.save(to: directory)
        return text
    }

    /// The half-finished submission recorded for this draft, if any (unreadable records are ignored).
    func pendingSubmission(in directory: URL) -> PendingSubmission? {
        let url = directory.appendingPathComponent(Self.pendingSubmissionFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ReviewBundle.makeDecoder().decode(PendingSubmission.self, from: data)
    }

    func savePendingSubmission(_ pending: PendingSubmission, in directory: URL) throws {
        let url = directory.appendingPathComponent(Self.pendingSubmissionFilename)
        try ReviewBundle.makeEncoder().encode(pending).write(to: url, options: .atomic)
    }

    /// True when `directory` is the current draft (the one new captures go to).
    func isCurrent(_ directory: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = try? loadCurrent() else { return false }
        return current.directory.standardizedFileURL.path == directory.standardizedFileURL.path
    }

    /// Removes a submitted draft: its media now lives in Hot Sheet. An untitled draft is deleted;
    /// a saved review (`HS2-BKWZ5N`) is moved to the Trash instead, so a file the reviewer chose
    /// a place for is never deleted outright. When it is the current draft, the pointer is
    /// removed too, so the next capture starts a new review. Refuses any directory that is not
    /// a draft or a saved review.
    func removeSubmitted(_ directory: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let target = try draftDirectory(directory)
        if currentDirectoryPath() == target.resolvingSymlinksInPath().path {
            try FileManager.default.removeItem(at: pointerURL)
        }
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        if isInRoot(target) {
            try FileManager.default.removeItem(at: target)
        } else {
            _ = try trash.move(target)
        }
    }
}
