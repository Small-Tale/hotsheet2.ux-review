import AppKit
import UXReviewKit

/// Receives images and movies opened from Finder ("Open With", or dropped on the app icon; the
/// document types are declared in project.yml). URLs that arrive within `batchDelay` of each
/// other import as one all-or-nothing batch into the current draft. Spec: docs/04-capture.md §4.12.1.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `UXReviewApp` to the capture coordinator, which owns the draft store. URLs that
    /// arrive before it is set wait in the batch.
    static var openHandler: (([URL]) -> Void)? {
        didSet { shared?.flushIfReady() }
    }

    private weak static var shared: AppDelegate?
    static let batchDelay: Duration = .milliseconds(300)
    private var batch = OpenBatch()
    private var waiting = false

    override init() {
        super.init()
        Self.shared = self
    }

    func application(_: NSApplication, open urls: [URL]) {
        guard batch.add(urls) else { return }
        waiting = true
        Task {
            try? await Task.sleep(for: Self.batchDelay)
            waiting = false
            flushIfReady()
        }
    }

    private func flushIfReady() {
        guard !waiting, let handler = Self.openHandler, !batch.pending.isEmpty else { return }
        handler(batch.flush())
    }
}

/// `UXReview --open-media FILE… [--drafts-dir DIR] [--into-draft DIR]`: routes files the way
/// Finder "Open With" (current draft) or a drop on an editor window (`--into-draft`) does,
/// without UI, and prints a JSON result. Used by scripts/app-e2e.sh. Exit codes as `--import`:
/// 0 opened, 2 bad arguments or a rejected file (nothing is imported), 5 the draft couldn't be
/// written. Spec: docs/04-capture.md §4.12.1.
@MainActor
enum HeadlessOpenMedia {
    struct Success: Encodable {
        var status = "opened"
        var draftDirectory: String
        /// The media the editor would show (the first imported item).
        var editorMediaId: String?
        var media: [MediaItem]
    }

    static func run(arguments: [String]) async -> Int32 {
        do {
            guard let command = try OpenMediaCommand.parse(arguments)
            else { return fail("invalidArguments", "missing --open-media", code: 2) }
            let store = ReviewDraftStore(root: command.draftsDirectory ?? AppSettings.draftsDirectory())
            let (draft, media) = try await MediaOpenRouting.open(command.files, into: store, draft: command.intoDraft)
            print(HeadlessCapture.json(Success(draftDirectory: draft.directory.path, editorMediaId: media.first?.id, media: media)))
            return 0
        } catch let error as CommandLineError {
            return fail("invalidArguments", error.description, code: 2)
        } catch let error as MediaImportError {
            return fail(error.code, error.description, code: 2)
        } catch {
            return fail("failed", String(describing: error), code: 5)
        }
    }

    private static func fail(_ error: String, _ message: String, code: Int32) -> Int32 {
        print(HeadlessCapture.json(HeadlessCapture.Failure(error: error, message: message)))
        return code
    }
}
