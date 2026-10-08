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

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(executable: URL, arguments: [String], environment: [String: String], currentDirectory _: URL?) throws -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        calls.append(Call(executable: executable, arguments: arguments, environment: environment))
        return results.isEmpty ? ProcessResult(exitCode: 0, stdout: "", stderr: "") : results.removeFirst()
    }
}

/// In-memory `HotSheetClient` for submitter tests.
final class FakeHotSheetClient: HotSheetClient, @unchecked Sendable {
    var created: [NewTicket] = []
    var attached: [(files: [URL], slug: String, label: String?, purpose: String?)] = []
    var createError: Error?
    /// Thrown by the next attaches (each failure consumes one entry), like a CLI failure.
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
}

/// Suites that encode or decode movies (AVAssetWriter, export sessions, AVPlayer) run one after
/// another: in parallel they exhaust the machine's video encoder sessions, and writers then wait
/// forever for `isReadyForMoreMediaData`. Nest such suites in an `extension EncodingTests`.
@Suite(.serialized)
enum EncodingTests {}
