import Foundation

/// Reviews as macOS documents (`HS2-BKWZ5N`, docs/07 §7.9): a review is a `.uxreview` package.
/// Untitled ones live in the drafts root; saving moves one wherever the reviewer chooses, and
/// it keeps autosaving there. Every operation runs under the store's lock.
public extension ReviewDraftStore {
    /// True for a review that was never saved: a folder directly inside the drafts root.
    func isUntitled(_ directory: URL) -> Bool { isInRoot(directory) }

    /// The review in `url`, a `.uxreview` package (or a draft folder): what File › Open… and
    /// Open Recent open. Throws `unreadableDraft` when it holds no readable review.json.
    func open(_ url: URL) throws -> ReviewDraft {
        lock.lock()
        defer { lock.unlock() }
        return try read(url.standardizedFileURL)
    }

    /// Makes `directory` the review new captures go to.
    func makeCurrent(_ directory: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try read(directory)
        try writePointer(to: directory)
    }

    /// `url` with the `.uxreview` extension (added when missing).
    static func packageURL(_ url: URL) -> URL {
        url.pathExtension == packageExtension ? url : url.appendingPathExtension(packageExtension)
    }

    /// Moves the review to `destination` (File › Save for an untitled review, docs/07 §7.9) and
    /// returns it there. The extension is added when missing. When it was current it stays
    /// current. A pending submission (§7.5) moves with it, so a retry still reuses its ticket.
    /// - Parameter replacing: an item already at `destination` (the save panel asked) goes to the
    ///   Trash first; otherwise `destinationExists`.
    @discardableResult
    func save(_ directory: URL, to destination: URL, replacing: Bool = false) throws -> ReviewDraft {
        lock.lock()
        defer { lock.unlock() }
        let target = Self.packageURL(destination.standardizedFileURL)
        _ = try read(directory)
        guard target.resolvingSymlinksInPath().path != directory.standardizedFileURL.resolvingSymlinksInPath().path else {
            return try read(directory)
        }
        try clear(target, replacing: replacing)
        let wasCurrent = currentDirectoryPath() == directory.standardizedFileURL.resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory, to: target)
        if wasCurrent { try writePointer(to: target) }
        return try read(target)
    }

    /// Writes a copy of the review to `destination` and returns the copy (Save As…, `HS2-0D87NR`).
    /// The copy is a fresh review: its id and pending-submission state are its own, so it never
    /// reuses the original's half-filed ticket. The original is left as it is.
    @discardableResult
    func saveCopy(_ directory: URL, to destination: URL, replacing: Bool = false) throws -> ReviewDraft {
        lock.lock()
        defer { lock.unlock() }
        let target = Self.packageURL(destination.standardizedFileURL)
        try clear(target, replacing: replacing)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try copyReview(directory, to: target, title: nil)
    }

    /// A new untitled review with everything `directory` has (Duplicate, `HS2-0D87NR`), titled
    /// "<title> copy". It doesn't become current.
    @discardableResult
    func duplicate(_ directory: URL) throws -> ReviewDraft {
        lock.lock()
        defer { lock.unlock() }
        let original = try read(directory)
        let target = root.appendingPathComponent("\(makeDraftIDForCopy()).\(Self.packageExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try copyReview(directory, to: target, title: "\(original.bundle.title) copy")
    }

    // MARK: Helpers (call with the lock held)

    /// Files that belong to one review's filing, never copied into another review.
    static let filingOnlyNames: Set<String> = [pendingSubmissionFilename, SubmissionStaging.folderName]

    private func copyReview(_ directory: URL, to target: URL, title: String?) throws -> ReviewDraft {
        var draft = try read(directory)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
        do {
            for name in try fileManager.contentsOfDirectory(atPath: directory.path) where !Self.filingOnlyNames.contains(name) {
                try fileManager.copyItem(at: directory.appendingPathComponent(name), to: target.appendingPathComponent(name))
            }
            draft.bundle.id = Self.reviewID(of: target)
            if let title { draft.bundle.title = title }
            try write(draft.bundle, to: target.appendingPathComponent(Self.bundleFilename))
        } catch {
            try? fileManager.removeItem(at: target)
            throw error
        }
        return try read(target)
    }

    private func clear(_ target: URL, replacing: Bool) throws {
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        guard replacing else { throw ReviewDraftError.destinationExists(target) }
        _ = try trash.move(target)
    }

    /// A review's id from its package name (`20261007-031500-4F2A9C.uxreview` →
    /// `20261007-031500-4F2A9C`), or a new one for a name that isn't an id.
    static func reviewID(of package: URL) -> String {
        let stem = package.deletingPathExtension().lastPathComponent
        return stem.range(of: #"^\d{8}-\d{6}-[0-9A-F]{6}$"#, options: .regularExpression) != nil ? stem : makeDraftID()
    }

    private func makeDraftIDForCopy() -> String {
        var id = Self.makeDraftID()
        while FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id).\(Self.packageExtension)").path) {
            id = Self.makeDraftID()
        }
        return id
    }
}
