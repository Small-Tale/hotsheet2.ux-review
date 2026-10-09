import Foundation
import Testing
@testable import UXReviewKit

enum TestSupport {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // UXReviewKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // macos
        .deletingLastPathComponent() // repo root

    static let exampleBundleURL = repoRoot.appendingPathComponent("spec/examples/review-bundle.example.json")

    static func exampleBundle() throws -> ReviewBundle {
        try ReviewBundle.makeDecoder().decode(ReviewBundle.self, from: Data(contentsOf: exampleBundleURL))
    }

    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uxreview-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    /// The plist file that would back a named defaults domain of the current user.
    static func userPreferencesFile(forDomain domain: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(domain).plist")
    }

    /// Runs `body` with a real `UserDefaults` suite kept in a temporary folder, then removes the
    /// folder. The suite name is an absolute path, so CFPreferences stores it in `<path>.plist`
    /// rather than in ~/Library/Preferences. A named suite can't be cleaned up from inside the
    /// test: `removePersistentDomain(forName:)` leaves an empty plist, and cfprefsd writes it
    /// again after the test process exits even when the test deletes it, so every run used to
    /// leak one `uxreview-tests-<UUID>` domain (HS2-1AD1FJ). Prefer `MemoryStore`; use this only
    /// to test the real `UserDefaults` conformance.
    static func withTemporaryDefaults<T>(_ body: (_ suite: String, _ defaults: UserDefaults) throws -> T) throws -> T {
        let folder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = folder.appendingPathComponent("defaults").path
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        return try body(suite, defaults)
    }

    static func image(_ id: String = "m1", filename: String = "shot.png") -> MediaItem {
        MediaItem(id: id, filename: filename, kind: .image, pixelWidth: 100, pixelHeight: 50, capturedAt: Date(timeIntervalSince1970: 0))
    }

    static func video(_ id: String = "v1", filename: String = "clip.mov", durationMs: Int = 5000) -> MediaItem {
        MediaItem(
            id: id, filename: filename, kind: .video, pixelWidth: 100, pixelHeight: 50,
            durationMs: durationMs, capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func bundle(media: [MediaItem] = [image()], annotations: [Annotation] = []) -> ReviewBundle {
        ReviewBundle(id: "b1", title: "Test", createdAt: Date(timeIntervalSince1970: 0), media: media, annotations: annotations)
    }
}

/// Records invocations and replays scripted results, faithful to `hotsheet-cli` output shapes.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
    }

    private let lock = NSLock()
    private var results: [ProcessResult]
    private(set) var calls: [Call] = []
    /// Called during each run, while files the arguments name (such as `annotate --file=`) exist.
    var onRun: ((Call) -> Void)?

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(executable: URL, arguments: [String], environment: [String: String], currentDirectory _: URL?) throws -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        let call = Call(executable: executable, arguments: arguments, environment: environment)
        calls.append(call)
        onRun?(call)
        return results.isEmpty ? ProcessResult(exitCode: 0, stdout: "", stderr: "") : results.removeFirst()
    }
}

/// In-memory `HotSheetClient` for submitter tests.
final class FakeHotSheetClient: HotSheetClient, @unchecked Sendable {
    var created: [NewTicket] = []
    var attached: [(files: [URL], slug: String, label: String?, purpose: String?)] = []
    /// The `batchID` of each successful or partial `attachReportingNames`, in order.
    var batchIDs: [String?] = []
    var createError: Error?
    /// Thrown by the next attaches (each failure consumes one entry), like a CLI failure. A
    /// `HotSheetError.attachIncomplete` whose `storedNames` holds N placeholders attaches the first
    /// N files first (recorded in `attached`, with their real stored names in the error), like
    /// `hotsheet-cli attach` stopping part-way.
    var attachErrors: [Error] = []
    /// Called with the files of each successful attach while they still exist (staged media is
    /// removed after submitting), so tests can read what Hot Sheet would receive.
    var inspectAttached: (([URL]) throws -> Void)?
    /// Number tickets so duplicates are visible (`HS-TEST01`, `HS-TEST02`, …).
    var numbered = false

    func createTicket(_ ticket: NewTicket) throws -> String {
        if let createError { throw createError }
        created.append(ticket)
        return numbered ? String(format: "HS-TEST%02d", created.count) : "HS-TEST01"
    }

    func attach(files: [URL], to slug: String, batchLabel: String?, purpose: String?) throws {
        if !attachErrors.isEmpty { throw attachErrors.removeFirst() }
        try inspectAttached?(files)
        attached.append((files, slug, batchLabel, purpose))
    }

    // MARK: Existing tickets

    /// Tickets `findTicket` knows, by slug.
    var tickets: [String: HotSheetTicket] = [:]
    var findError: Error?
    var notes: [(slug: String, markdown: String)] = []
    /// Thrown by the next notes (each failure consumes one entry).
    var noteErrors: [Error] = []
    /// Names the ticket already has: a file attached under one of them is stored as `name (2).ext`,
    /// like `hotsheet-cli attach`.
    var existingNames: Set<String> = []

    func attachReportingNames(files: [URL], to slug: String, batchLabel: String?, purpose: String?, batchID: String?) throws -> [String] {
        if case let HotSheetError.attachIncomplete(placeholders, exitCode, stderr)? = attachErrors.first {
            attachErrors.removeFirst()
            let done = Array(files.prefix(placeholders.count))
            try inspectAttached?(done)
            attached.append((done, slug, batchLabel, purpose))
            batchIDs.append(batchID)
            throw HotSheetError.attachIncomplete(storedNames: storedNames(for: done), exitCode: exitCode, stderr: stderr)
        }
        try attach(files: files, to: slug, batchLabel: batchLabel, purpose: purpose)
        batchIDs.append(batchID)
        return storedNames(for: files)
    }

    /// The names Hot Sheet would store `files` under, given the names the ticket already has.
    private func storedNames(for files: [URL]) -> [String] {
        files.map { file in
            let name = file.lastPathComponent
            var stored = name
            var counter = 2
            while existingNames.contains(stored) {
                let ext = (name as NSString).pathExtension
                let stem = (name as NSString).deletingPathExtension
                stored = "\(stem) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)")
                counter += 1
            }
            existingNames.insert(stored)
            return stored
        }
    }

    func findTicket(_ reference: String) throws -> HotSheetTicket? {
        if let findError { throw findError }
        return tickets[reference] ?? tickets.values.first { $0.id == reference }
    }

    /// Tickets moved to the Trash, in order.
    var trashed: [String] = []
    var trashError: Error?

    func moveToTrash(_ slug: String) throws {
        if let trashError { throw trashError }
        trashed.append(slug)
    }

    func addNote(_ markdown: String, to slug: String) throws {
        if !noteErrors.isEmpty { throw noteErrors.removeFirst() }
        notes.append((slug, markdown))
    }

    // MARK: Annotations

    /// False acts like a `hotsheet-cli` without `annotate`.
    var annotationSupport = true
    /// What `annotate` keeps, like the Hot Sheet 2 generations: everything; the box and text only
    /// (shapes and intents silently dropped, as before they existed); or a rejection of shapes and
    /// intents (`annotations require …`, exit 1).
    enum AnnotationDialect { case native, boxesOnly, rejectsNative }
    var annotationDialect = AnnotationDialect.native
    /// Each `annotate`, in order: the stored file name it targeted and the annotations.
    var annotated: [(slug: String, filename: String, annotations: [HotSheetMediaAnnotation])] = []
    /// Thrown by the next annotates (each failure consumes one entry).
    var annotateErrors: [Error] = []
    var attachmentIDsError: Error?

    /// Every stored name gets the id `ID-<name>`, like the ULIDs `hotsheet-cli show` lists.
    func attachmentIDs(on _: String) throws -> [String: String] {
        if let attachmentIDsError { throw attachmentIDsError }
        return Dictionary(uniqueKeysWithValues: existingNames.map { ($0, "ID-\($0)") })
    }

    func annotate(_ annotations: [HotSheetMediaAnnotation], attachmentID: String, on slug: String) throws -> [HotSheetMediaAnnotation]? {
        guard annotationSupport else { throw HotSheetError.annotationsUnsupported }
        if !annotateErrors.isEmpty { throw annotateErrors.removeFirst() }
        let native = annotations.contains { $0.shape != nil || $0.intents != nil }
        if native, annotationDialect == .rejectsNative {
            throw HotSheetError.commandFailed(command: "annotate", exitCode: 1, stderr: "Error: annotations require unique ids")
        }
        var stored = annotations
        if annotationDialect == .boxesOnly {
            for index in stored.indices {
                stored[index].shape = nil
                stored[index].intents = nil
            }
        }
        annotated.append((slug, String(attachmentID.dropFirst("ID-".count)), stored))
        return stored
    }

    /// What `aiSettings` returns or throws (`hotsheet-cli ai-settings get --json`); unknown by default.
    var aiTool: Result<AIToolSettings?, Error> = .success(nil)

    func aiSettings() throws -> AIToolSettings? { try aiTool.get() }
}

/// Suites that encode or decode movies (AVAssetWriter, export sessions, AVPlayer) run one after
/// another: in parallel they exhaust the machine's video encoder sessions, and writers then wait
/// forever for `isReadyForMoreMediaData`. Nest such suites in an `extension EncodingTests`.
@Suite(.serialized)
enum EncodingTests {}
