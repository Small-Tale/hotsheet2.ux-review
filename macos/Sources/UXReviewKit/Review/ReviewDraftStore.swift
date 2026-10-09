import Foundation

/// One captured file waiting to be added to the current draft review.
public struct DraftCapture: Sendable {
    /// The captured file. `ReviewDraftStore.add` moves it into the draft directory.
    public var fileURL: URL
    public var kind: MediaKind
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var durationMs: Int?
    public var capturedAt: Date
    public var context: CaptureContext
    /// Video only: the movie has an audio track (narration, or an imported movie's sound).
    public var hasAudio: Bool

    public init(
        fileURL: URL,
        kind: MediaKind,
        pixelWidth: Int,
        pixelHeight: Int,
        durationMs: Int? = nil,
        capturedAt: Date,
        context: CaptureContext,
        hasAudio: Bool = false
    ) {
        self.fileURL = fileURL
        self.kind = kind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationMs = durationMs
        self.capturedAt = capturedAt
        self.context = context
        self.hasAudio = hasAudio
    }
}

/// A review in progress: a directory holding the captured media and a draft `review.json`.
public struct ReviewDraft: Equatable, Sendable {
    public var directory: URL
    public var bundle: ReviewBundle

    public var bundleURL: URL { directory.appendingPathComponent(ReviewDraftStore.bundleFilename) }

    public func mediaURL(_ item: MediaItem) -> URL {
        directory.appendingPathComponent(item.filename)
    }
}

public enum ReviewDraftError: Error, Equatable, CustomStringConvertible {
    case missingCaptureFile(URL)
    case unreadableDraft(URL)
    case unknownMedia(String)
    case outsideDrafts(URL)
    case noSuchDraft(URL)
    case trashFailed(URL, String)
    case deleteFailed(URL, String)
    /// Saving would replace something already there (`HS2-BKWZ5N`).
    case destinationExists(URL)

    /// The Trash refused the draft, so it can be offered for immediate deletion instead
    /// (docs/07 §7.9).
    public var canDeleteInstead: Bool { trashRefusal != nil }

    /// Why the Trash refused the draft (the system's message), for `trashFailed` only.
    public var trashRefusal: String? {
        if case let .trashFailed(_, reason) = self { reason } else { nil }
    }

    public var description: String {
        switch self {
        case let .missingCaptureFile(url): "The captured file is missing: \(url.path)"
        case let .unreadableDraft(url): "The draft review could not be read: \(url.path)"
        case let .unknownMedia(id): "The review has no capture \(id)."
        case let .outsideDrafts(url): "\(url.path) is not a draft review."
        case let .noSuchDraft(url): "There is no draft review at \(url.path)."
        case let .trashFailed(url, reason): "\(url.lastPathComponent) couldn't be moved to the Trash: \(reason)"
        case let .deleteFailed(url, reason): "\(url.lastPathComponent) couldn't be deleted: \(reason)"
        case let .destinationExists(url): "\(url.lastPathComponent) already exists."
        }
    }
}

/// Collects captures into the current draft review on disk. Captures keep accumulating in one
/// draft until `startNew()`; the annotation editor (docs/06) edits drafts and the review session UI
/// (HS2-CRJDJ8) submits them.
/// Layout: `<root>/<draft id>/{review.json, capture-1.png, …}` plus `<root>/current`, which
/// names the current draft directory. Spec: docs/04-capture.md §4.6.
public final class ReviewDraftStore: @unchecked Sendable {
    public static let bundleFilename = "review.json"
    static let currentPointerFilename = "current"
    /// A review on disk is a `.uxreview` package (`HS2-BKWZ5N`, docs/04 §4.6): untitled ones in
    /// the drafts root, saved ones wherever the reviewer put them. Drafts made before keep their
    /// plain folder names.
    public static let packageExtension = "uxreview"

    public let root: URL
    /// Where `discard` puts a draft: the Trash, or a folder (tests). Spec: docs/07 §7.9.
    public let trash: DraftTrash
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String
    let lock = NSLock()

    public init(
        root: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> String = ReviewDraftStore.makeDraftID,
        trash: DraftTrash = .system
    ) {
        self.root = root
        self.trash = trash
        self.now = now
        self.makeID = makeID
    }

    /// `~/Library/Application Support/UX Review/Drafts`.
    public static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("UX Review/Drafts", isDirectory: true)
    }

    /// Sortable, unique draft id such as `20261007-031500-4F2A9C`.
    @Sendable public static func makeDraftID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)
        return "\(formatter.string(from: Date()))-\(suffix)"
    }

    var pointerURL: URL { root.appendingPathComponent(Self.currentPointerFilename) }

    /// The current draft, or nil when none has been started (or the pointer is stale).
    public func current() throws -> ReviewDraft? {
        lock.lock()
        defer { lock.unlock() }
        return try loadCurrent()
    }

    /// Ends the current draft; the next capture starts a new one. The old draft stays on disk.
    public func startNew() throws {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: pointerURL.path) {
            try FileManager.default.removeItem(at: pointerURL)
        }
    }

    /// Starts a new, empty draft and makes it current (New Review, ⌘N): captures and added
    /// media then go into it. The previous draft stays on disk. Spec: docs/07 §7.9.
    @discardableResult
    public func createEmptyDraft() throws -> ReviewDraft {
        lock.lock()
        defer { lock.unlock() }
        let draft = try createDraft(context: CaptureContext())
        try write(draft.bundle, to: draft.bundleURL)
        try writePointer(to: draft.directory)
        return draft
    }

    /// Moves the captured file into the current draft (creating a draft if needed), appends its
    /// `MediaItem`, and rewrites `review.json`. On failure the draft is left unchanged.
    /// With `directory`, adds to that existing draft instead (for example the one an editor
    /// window shows) and leaves which draft is current alone.
    @discardableResult
    public func add(_ capture: DraftCapture, to directory: URL? = nil) throws -> (draft: ReviewDraft, media: MediaItem) {
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: capture.fileURL.path) else {
            throw ReviewDraftError.missingCaptureFile(capture.fileURL)
        }
        var draft = try directory.map(read) ?? loadCurrent() ?? createDraft(context: capture.context)

        let number = nextCaptureNumber(in: draft)
        let ext = capture.fileURL.pathExtension.isEmpty ? (capture.kind == .image ? "png" : "mov") : capture.fileURL.pathExtension
        let item = MediaItem(
            id: nextMediaID(in: draft),
            filename: "capture-\(number).\(ext.lowercased())",
            kind: capture.kind,
            pixelWidth: capture.pixelWidth,
            pixelHeight: capture.pixelHeight,
            durationMs: capture.durationMs,
            capturedAt: capture.capturedAt,
            context: capture.context.isEmpty ? nil : capture.context,
            hasAudio: capture.kind == .video && capture.hasAudio
        )
        let destination = draft.mediaURL(item)
        try fileManager.moveItem(at: capture.fileURL, to: destination)

        var bundle = draft.bundle
        bundle.media.append(item)
        if bundle.context.isEmpty { bundle.context = capture.context }
        do {
            try write(bundle, to: draft.bundleURL)
        } catch {
            try? fileManager.moveItem(at: destination, to: capture.fileURL)
            throw error
        }
        draft.bundle = bundle
        if directory == nil {
            try writePointer(to: draft.directory)
        }
        return (draft, item)
    }

    /// Reads the draft in `directory` (any draft, not only the current one).
    public func load(_ directory: URL) throws -> ReviewDraft {
        lock.lock()
        defer { lock.unlock() }
        return try read(directory)
    }

    /// Re-reads the draft in `directory`, applies `change`, and writes it back, all under the
    /// store's lock, so captures appended meanwhile are never lost. The annotation editor saves
    /// this way (docs/06-annotation-editor.md §6.7).
    @discardableResult
    public func update(_ directory: URL, _ change: (inout ReviewBundle) throws -> Void) throws -> ReviewDraft {
        lock.lock()
        defer { lock.unlock() }
        var draft = try read(directory)
        try change(&draft.bundle)
        try write(draft.bundle, to: draft.bundleURL)
        return draft
    }

    func read(_ directory: URL) throws -> ReviewDraft {
        let bundleURL = directory.appendingPathComponent(Self.bundleFilename)
        do {
            let bundle = try ReviewBundle.makeDecoder().decode(ReviewBundle.self, from: Data(contentsOf: bundleURL))
            return ReviewDraft(directory: directory, bundle: bundle)
        } catch {
            throw ReviewDraftError.unreadableDraft(bundleURL)
        }
    }

    func loadCurrent() throws -> ReviewDraft? {
        guard let directory = pointedDirectory() else { return nil }
        let bundleURL = directory.appendingPathComponent(Self.bundleFilename)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else { return nil }
        return try read(directory)
    }

    private func createDraft(context: CaptureContext) throws -> ReviewDraft {
        let id = makeID()
        let directory = root.appendingPathComponent("\(id).\(Self.packageExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let title = context.appName.map { "\($0) review" } ?? "UX review"
        let bundle = ReviewBundle(id: id, title: title, createdAt: now(), context: context, media: [], annotations: [])
        return ReviewDraft(directory: directory, bundle: bundle)
    }

    /// The folder the `current` pointer names: a name directly inside the root, or the absolute
    /// path of a saved review elsewhere (`HS2-BKWZ5N`). Nil when there is none or it is malformed.
    func pointedDirectory() -> URL? {
        guard let value = try? String(contentsOf: pointerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        if value.hasPrefix("/") {
            let url = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
            return url.pathExtension == Self.packageExtension ? url : nil
        }
        guard !value.contains("/") else { return nil }
        return root.appendingPathComponent(value, isDirectory: true)
    }

    /// Makes `directory` current: by name when it is directly inside the root, else by path.
    func writePointer(to directory: URL) throws {
        let standardized = directory.standardizedFileURL
        let inRoot = standardized.deletingLastPathComponent().resolvingSymlinksInPath().path
            == root.standardizedFileURL.resolvingSymlinksInPath().path
        let value = inRoot ? standardized.lastPathComponent : standardized.path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(value.utf8).write(to: pointerURL, options: .atomic)
    }

    func write(_ bundle: ReviewBundle, to url: URL) throws {
        try ReviewBundle.makeEncoder().encode(bundle).write(to: url, options: .atomic)
    }

    /// One more than the highest `capture-N` ever used in the draft (including removed
    /// captures, `numbering.json`), skipping files that exist on disk.
    private func nextCaptureNumber(in draft: ReviewDraft) -> Int {
        let used = draft.bundle.media.compactMap { Self.captureNumber(of: $0.filename) }
        var number = max(used.max() ?? 0, DraftNumbering.load(from: draft.directory).lastCapture) + 1
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: draft.directory.path)) ?? []
        while existing.contains(where: { ($0 as NSString).deletingPathExtension == "capture-\(number)" }) {
            number += 1
        }
        return number
    }

    /// `m<N>` after every id the draft has used, including removed captures' (`numbering.json`).
    private func nextMediaID(in draft: ReviewDraft) -> String {
        let used = Set(draft.bundle.media.map(\.id))
        let highest = draft.bundle.media.compactMap { Self.mediaNumber(of: $0.id) }.max() ?? 0
        var number = max(draft.bundle.media.count, highest, DraftNumbering.load(from: draft.directory).lastMedia) + 1
        while used.contains("m\(number)") {
            number += 1
        }
        return "m\(number)"
    }

    /// N for a `capture-N.ext` file name, else nil.
    static func captureNumber(of filename: String) -> Int? {
        let stem = (filename as NSString).deletingPathExtension
        guard stem.hasPrefix("capture-") else { return nil }
        return Int(stem.dropFirst("capture-".count))
    }

    /// N for an `mN` media id, else nil.
    static func mediaNumber(of id: String) -> Int? {
        guard id.hasPrefix("m") else { return nil }
        return Int(id.dropFirst())
    }
}
