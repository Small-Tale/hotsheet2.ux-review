import Foundation

/// A ticket created for a draft whose attachments have not been written yet (the attach failed).
/// Kept in `<draft>/submission.json` so a retry attaches to that ticket instead of creating a
/// second one. Spec: docs/07-review-session.md §7.5.
public struct PendingSubmission: Codable, Equatable, Sendable {
    /// The store the ticket was created in. A retry into a different store starts over.
    public var storePath: String
    public var ticket: CreatedTicket
    public var createdAt: Date

    public init(storePath: String, ticket: CreatedTicket, createdAt: Date) {
        self.storePath = storePath
        self.ticket = ticket
        self.createdAt = createdAt
    }
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
    /// original (`originals/<file>` plus its crop/trim record). Nothing changes when `mediaId`
    /// is unknown or review.json can't be written; leftover files are removed best effort.
    @discardableResult
    func removeMedia(_ mediaId: String, from directory: URL) throws -> ReviewDraft {
        lock.lock()
        defer { lock.unlock() }
        var draft = try read(directory)
        guard let item = draft.bundle.media.first(where: { $0.id == mediaId }) else {
            throw ReviewDraftError.unknownMedia(mediaId)
        }
        draft.bundle.media.removeAll { $0.id == mediaId }
        draft.bundle.annotations.removeAll { $0.mediaId == mediaId }
        try write(draft.bundle, to: draft.bundleURL)

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: draft.mediaURL(item))
        let originals = directory.appendingPathComponent(EditorSession.originalsDirectory, isDirectory: true)
        let original = originals.appendingPathComponent(item.filename)
        if fileManager.fileExists(atPath: original.path) { try? fileManager.removeItem(at: original) }
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
