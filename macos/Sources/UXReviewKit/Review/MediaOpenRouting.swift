import Foundation

/// What to do with files handed to UX Review from outside: Finder "Open With", files dropped on
/// the app icon, files dragged onto an editor window, or headless `--open-media`.
public enum MediaOpenPlan: Equatable, Sendable {
    /// Import these files, in this order, with duplicates removed.
    case importFiles([URL])
    /// Import nothing, because of this file (the first problem in the order given).
    case reject(MediaImportError)
}

/// Decides how a batch of opened or dropped URLs is routed, before anything is copied. Like the
/// importer it is all-or-nothing: one missing, unsupported, or non-file item rejects the whole
/// batch. Spec: docs/04-capture.md §4.12.1.
public enum MediaOpenRouting {
    public static func plan(_ urls: [URL], fileManager: FileManager = .default) -> MediaOpenPlan {
        var seen = Set<String>()
        var files: [URL] = []
        for url in urls {
            guard url.isFileURL else { return .reject(.unsupported(url)) }
            let file = url.standardizedFileURL
            guard seen.insert(file.resolvingSymlinksInPath().path).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory) else { return .reject(.missing(file)) }
            guard !isDirectory.boolValue, MediaImporter.kind(of: file) != nil else { return .reject(.unsupported(file)) }
            files.append(file)
        }
        return files.isEmpty ? .reject(.nothingToImport) : .importFiles(files)
    }

    /// Runs the plan through `MediaImporter.importFiles`, into `draft` when given (a drop on an
    /// editor window) or else the current draft (Open With). Throws the rejection, if any.
    public static func open(
        _ urls: [URL],
        into store: ReviewDraftStore,
        draft directory: URL? = nil
    ) async throws -> (draft: ReviewDraft, media: [MediaItem]) {
        switch plan(urls) {
        case let .reject(error): throw error
        case let .importFiles(files): return try await MediaImporter.importFiles(files, into: store, draft: directory)
        }
    }
}

/// Collects URLs that arrive in quick succession so they import as one batch. Launch Services
/// may deliver a multi-file "Open With" as several `application(_:open:)` calls.
public struct OpenBatch: Sendable {
    public private(set) var pending: [URL] = []

    public init() {}

    /// Adds URLs. Returns true when this starts a new batch, so the caller should schedule a flush.
    public mutating func add(_ urls: [URL]) -> Bool {
        let started = pending.isEmpty && !urls.isEmpty
        pending += urls
        return started
    }

    /// Returns and clears everything collected so far.
    public mutating func flush() -> [URL] {
        defer { pending = [] }
        return pending
    }
}

/// Headless open invocation of the app, used by scripts and end-to-end tests. It routes files the
/// way Finder "Open With" (current draft) or a drop on an editor (`--into-draft`) does:
///
///     UXReview --open-media FILE [FILE…] [--drafts-dir DIR] [--into-draft DIR]
///
/// Spec: docs/04-capture.md §4.12.1.
public struct OpenMediaCommand: Equatable, Sendable {
    public var files: [URL]
    public var draftsDirectory: URL?
    public var intoDraft: URL?

    public init(files: [URL], draftsDirectory: URL? = nil, intoDraft: URL? = nil) {
        self.files = files
        self.draftsDirectory = draftsDirectory
        self.intoDraft = intoDraft
    }

    /// Returns nil when `--open-media` is absent. Files are every non-flag argument after
    /// `--open-media`, up to the next flag.
    public static func parse(_ arguments: [String]) throws -> OpenMediaCommand? {
        guard let index = arguments.firstIndex(of: "--open-media") else { return nil }
        let values = ArgumentValues(arguments)
        let files = arguments[(index + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty else { throw CommandLineError.missingValue("--open-media") }
        return try OpenMediaCommand(
            files: files,
            draftsDirectory: values.optional("--drafts-dir").map { URL(fileURLWithPath: $0, isDirectory: true) },
            intoDraft: values.optional("--into-draft").map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }
}
