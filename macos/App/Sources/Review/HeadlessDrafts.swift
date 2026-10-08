import Foundation
import UXReviewKit

/// `UXReview --drafts [--drafts-dir DIR]` lists every draft review as JSON;
/// `UXReview --discard-draft NAME|PATH [--delete] [--drafts-dir DIR]` moves one to the Trash
/// (`UXREVIEW_TRASH_DIR` redirects it, for scripts/app-e2e.sh), or with `--delete` deletes it
/// immediately. Exit codes: 0 done,
/// 2 bad arguments or no such draft, 5 the draft couldn't be listed or moved, 6 not a draft
/// folder inside the drafts directory. Spec: docs/07-review-session.md §7.10.
@MainActor
enum HeadlessDrafts {
    struct Draft: Encodable {
        var name: String
        var directory: String
        var title: String
        var captureCount: Int
        var annotationCount: Int
        var createdAt: Date?
        var modifiedAt: Date
        var isCurrent: Bool
        var pendingTicket: String?
        /// Set when `pendingTicket` is an existing ticket that has the media but not the note yet.
        var pendingNoteOnly: Bool?
        /// Set when `pendingTicket` is an existing ticket the review was being added to.
        var pendingToExisting: Bool?
        /// Set when only some of the review's files are attached to `pendingTicket`.
        var pendingPartlyAttached: Bool?
        var issue: String?

        init(_ summary: DraftSummary) {
            name = summary.name
            directory = summary.directory.path
            title = summary.title
            captureCount = summary.captureCount
            annotationCount = summary.annotationCount
            createdAt = summary.createdAt
            modifiedAt = summary.modifiedAt
            isCurrent = summary.isCurrent
            pendingTicket = summary.pendingTicket
            pendingNoteOnly = summary.pendingNoteOnly ? true : nil
            pendingToExisting = summary.pendingToExisting ? true : nil
            pendingPartlyAttached = summary.pendingPartlyAttached ? true : nil
            issue = summary.issue
        }
    }

    struct Listing: Encodable {
        var status = "listed"
        var draftsDirectory: String
        var drafts: [Draft]
    }

    struct Discarded: Encodable {
        /// "discarded" (moved to the Trash) or "deleted" (`--delete`).
        var status: String
        var draftDirectory: String
        var trashedTo: String?
        var wasCurrent: Bool
    }

    struct Failure: Encodable {
        var status = "error"
        var error: String
        var message: String
    }

    static func run(arguments: [String]) -> Int32 {
        let command: DraftsCommand
        do {
            guard let parsed = try DraftsCommand.parse(arguments) else {
                return fail("invalidArguments", "missing --drafts or --discard-draft", code: 2)
            }
            command = parsed
        } catch {
            return fail("invalidArguments", String(describing: error), code: 2)
        }
        let store = ReviewDraftStore(
            root: command.draftsDirectory ?? AppSettings.draftsDirectory(),
            trash: DraftTrash.from(environment: ProcessInfo.processInfo.environment)
        )
        guard let target = command.target(in: store.root) else { return list(store) }
        do {
            let result = try store.discard(target, deleteImmediately: command.deletesImmediately)
            print(HeadlessCapture.json(Discarded(
                status: result.deleted ? "deleted" : "discarded",
                draftDirectory: result.directory.path,
                trashedTo: result.trashedTo?.path,
                wasCurrent: result.wasCurrent
            )))
            return 0
        } catch let error as ReviewDraftError {
            switch error {
            case .outsideDrafts: return fail("outsideDrafts", error.description, code: 6)
            case .noSuchDraft: return fail("noDraft", error.description, code: 2)
            default: return fail("discardFailed", error.description, code: 5)
            }
        } catch {
            return fail("discardFailed", String(describing: error), code: 5)
        }
    }

    private static func list(_ store: ReviewDraftStore) -> Int32 {
        do {
            let drafts = try store.listDrafts()
            print(HeadlessCapture.json(Listing(draftsDirectory: store.root.path, drafts: drafts.map(Draft.init))))
            return 0
        } catch {
            return fail("listFailed", ReviewSubmitter.describe(error), code: 5)
        }
    }

    private static func fail(_ error: String, _ message: String, code: Int32) -> Int32 {
        print(HeadlessCapture.json(Failure(error: error, message: message)))
        return code
    }
}
