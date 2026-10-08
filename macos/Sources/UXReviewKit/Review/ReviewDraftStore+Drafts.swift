import Foundation

/// One draft review on disk, as the Draft Reviews window and `--drafts` list it.
/// Spec: docs/07-review-session.md §7.9.
public struct DraftSummary: Equatable, Sendable, Identifiable {
    public var directory: URL
    /// The review's title, or the folder name when the draft can't be read.
    public var title: String
    public var captureCount: Int
    public var annotationCount: Int
    /// When the draft was started (`createdAt` in review.json); nil when unreadable.
    public var createdAt: Date?
    /// When review.json last changed (a capture, an editor save, a title), else the folder's date.
    public var modifiedAt: Date
    /// New captures go to this draft.
    public var isCurrent: Bool
    /// The ticket already created for this draft when attaching its media failed (§7.5).
    public var pendingTicket: String?
    /// The pending ticket is an existing one the review was being added to: its media is attached
    /// and the review note is still missing (§7.5).
    public var pendingNoteOnly = false
    /// The pending ticket is an existing one the review was being added to (not one it created).
    public var pendingToExisting = false
    /// Some, not all, of the review's files are attached to the pending ticket (§7.5).
    public var pendingPartlyAttached = false
    /// Why the draft can't be opened (missing or corrupt review.json); nil when it reads fine.
    public var issue: String?

    public var name: String { directory.lastPathComponent }
    public var id: String { name }
    public var isReadable: Bool { issue == nil }

    public init(
        directory: URL,
        title: String,
        captureCount: Int = 0,
        annotationCount: Int = 0,
        createdAt: Date? = nil,
        modifiedAt: Date,
        isCurrent: Bool = false,
        pendingTicket: String? = nil,
        issue: String? = nil
    ) {
        self.directory = directory
        self.title = title
        self.captureCount = captureCount
        self.annotationCount = annotationCount
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isCurrent = isCurrent
        self.pendingTicket = pendingTicket
        self.issue = issue
    }
}

/// Where a discarded draft goes.
public enum DraftTrash: Equatable, Sendable {
    /// The user's Trash (`FileManager.trashItem`), so a mistaken discard can be put back.
    case system
    /// A plain folder, for tests and `scripts/app-e2e.sh` (`UXREVIEW_TRASH_DIR`), so they never
    /// fill the real Trash.
    case folder(URL)

    /// `UXREVIEW_TRASH_DIR` when set, else the system Trash.
    public static func from(environment: [String: String]) -> DraftTrash {
        guard let path = environment["UXREVIEW_TRASH_DIR"], !path.isEmpty else { return .system }
        return .folder(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Moves `url` away and returns where it went (nil when the system doesn't say).
    func move(_ url: URL) throws -> URL? {
        switch self {
        case .system:
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return result as URL?
        case let .folder(folder):
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var destination = folder.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            var copy = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent("\(url.lastPathComponent) \(copy)", isDirectory: true)
                copy += 1
            }
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }
}

/// What `discard` did.
public struct DiscardedDraft: Equatable, Sendable {
    public var directory: URL
    /// Where the folder went (in the Trash), when known.
    public var trashedTo: URL?
    /// It was the current draft, so the next capture starts a new review.
    public var wasCurrent: Bool
    /// Deleted outright instead of moved to the Trash (`deleteImmediately`); can't be undone.
    public var deleted = false
}

/// Every draft on disk, and discarding one. Spec: docs/07-review-session.md §7.9.
public extension ReviewDraftStore {
    /// Every draft folder directly inside the drafts root, most recently edited first. Hidden
    /// entries, the `current` pointer, plain files, and symbolic links are skipped. A folder whose
    /// review.json is missing or corrupt is listed with an `issue`, so it can still be discarded.
    /// A missing root lists nothing.
    func listDrafts() throws -> [DraftSummary] {
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let entries = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        let current = currentDirectoryPath()
        return entries.compactMap { entry -> DraftSummary? in
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true
            else { return nil }
            let directory = root.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
            return summarize(directory, folderDate: values.contentModificationDate, current: current)
        }
        .sorted { ($0.modifiedAt, $0.name) > ($1.modifiedAt, $1.name) }
    }

    /// The listing entry for one draft folder (what the Discard confirmation describes).
    /// Throws `outsideDrafts` like `discard`, and `noSuchDraft` when the folder is gone.
    func summary(of directory: URL) throws -> DraftSummary {
        lock.lock()
        defer { lock.unlock() }
        let target = try draftDirectory(directory)
        let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
        guard values?.isDirectory == true else { throw ReviewDraftError.noSuchDraft(directory) }
        return summarize(target, folderDate: values?.contentModificationDate, current: currentDirectoryPath())
    }

    /// Moves a draft folder to the Trash (or `trash`'s folder). When it is the current draft,
    /// the `current` pointer is removed too, so the next capture starts a new review. Refuses
    /// anything that is not a draft folder directly inside the drafts root (the root itself,
    /// `current`, hidden names, nested folders, symbolic links). When the move fails, nothing
    /// changes: the draft is never deleted outright unless `deleteImmediately` asks for it.
    ///
    /// With `deleteImmediately`, the folder is removed for good instead, without trying the
    /// Trash. The Draft Reviews window offers that only after the Trash refused and the
    /// reviewer confirmed a second time; `--discard-draft … --delete` asks for it directly
    /// (docs/07 §7.9, §7.10). The same folders are refused. If removal fails part-way, whatever
    /// is left stays in place and the pointer is kept.
    @discardableResult
    func discard(_ directory: URL, deleteImmediately: Bool = false) throws -> DiscardedDraft {
        lock.lock()
        defer { lock.unlock() }
        let target = try draftDirectory(directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReviewDraftError.noSuchDraft(directory)
        }
        let wasCurrent = currentDirectoryPath() == target.path
        var trashedTo: URL?
        if deleteImmediately {
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                throw ReviewDraftError.deleteFailed(directory, (error as NSError).localizedDescription)
            }
        } else {
            do {
                trashedTo = try trash.move(target)
            } catch {
                throw ReviewDraftError.trashFailed(directory, (error as NSError).localizedDescription)
            }
        }
        // A pointer left behind would be stale and ignored (§4.6), so a failure here is harmless.
        if wasCurrent { try? FileManager.default.removeItem(at: pointerURL) }
        return DiscardedDraft(directory: target, trashedTo: trashedTo, wasCurrent: wasCurrent, deleted: deleteImmediately)
    }

    private func summarize(_ directory: URL, folderDate: Date?, current: String?) -> DraftSummary {
        let bundleURL = directory.appendingPathComponent(Self.bundleFilename)
        let bundleDate = (try? bundleURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let pending = pendingSubmission(in: directory)
        var summary = DraftSummary(
            directory: directory,
            title: directory.lastPathComponent,
            modifiedAt: bundleDate ?? folderDate ?? .distantPast,
            isCurrent: current == directory.standardizedFileURL.resolvingSymlinksInPath().path,
            pendingTicket: pending?.ticket.slug
        )
        summary.pendingNoteOnly = pending?.isNotePending == true
        summary.pendingToExisting = pending?.isForExistingTicket == true
        summary.pendingPartlyAttached = pending?.isPartlyAttached == true
        if !FileManager.default.fileExists(atPath: bundleURL.path) {
            summary.issue = "review.json is missing."
        } else if let draft = try? read(directory) {
            summary.title = draft.bundle.title
            summary.captureCount = draft.bundle.media.count
            summary.annotationCount = draft.bundle.annotations.count
            summary.createdAt = draft.bundle.createdAt
        } else {
            summary.issue = "review.json can't be read."
        }
        return summary
    }
}

extension ReviewDraftStore {
    /// `directory` as a draft folder directly inside the root (with the root's symbolic links
    /// resolved), or `outsideDrafts`.
    func draftDirectory(_ directory: URL) throws -> URL {
        let standardized = directory.standardizedFileURL
        let name = standardized.lastPathComponent
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        guard parent.path == base.path, !name.isEmpty, name != "/", name != Self.currentPointerFilename, !name.hasPrefix(".")
        else { throw ReviewDraftError.outsideDrafts(directory) }
        let target = base.appendingPathComponent(name, isDirectory: true)
        let type = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.type] as? FileAttributeType
        guard type != .typeSymbolicLink else { throw ReviewDraftError.outsideDrafts(directory) }
        return target
    }

    /// The resolved path of the folder the `current` pointer names, whether or not it reads.
    func currentDirectoryPath() -> String? {
        guard let name = try? String(contentsOf: pointerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !name.contains("/")
        else { return nil }
        return root.appendingPathComponent(name, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
