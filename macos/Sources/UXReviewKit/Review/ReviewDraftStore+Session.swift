import Foundation

/// A half-finished submission, kept in `<draft>/submission.json` so a retry finishes it instead of
/// writing anything twice. Spec: docs/07-review-session.md §7.5.
/// - A ticket was created but its attach failed (`attachedNames` nil): the retry attaches to it
///   instead of creating a second ticket.
/// - The review was being added to an existing ticket, its media is attached, but the note failed
///   (`attachedNames` set): the retry adds only the note.
public struct PendingSubmission: Codable, Equatable, Sendable {
    /// The store the ticket is in. A retry into a different store starts over.
    public var storePath: String
    public var ticket: CreatedTicket
    public var createdAt: Date
    /// Adding to an existing ticket: the batch already attached, draft file name → stored name.
    public var attachedNames: [String: String]?

    public init(storePath: String, ticket: CreatedTicket, createdAt: Date, attachedNames: [String: String]? = nil) {
        self.storePath = storePath
        self.ticket = ticket
        self.createdAt = createdAt
        self.attachedNames = attachedNames
    }

    /// True for an existing ticket whose media is attached and whose note is still missing.
    public var isAddedToExistingTicket: Bool { attachedNames != nil }
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

    /// Deletes a submitted draft: its media now lives in Hot Sheet. When it is the current
    /// draft, the pointer is removed too, so the next capture starts a new review. Refuses any
    /// directory that is not directly inside the drafts root.
    func removeSubmitted(_ directory: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let target = try draftDirectory(directory)
        if currentDirectoryPath() == target.path {
            try FileManager.default.removeItem(at: pointerURL)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }
}
