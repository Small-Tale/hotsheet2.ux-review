import AppKit
import UXReviewKit

/// `UXReview --submit [--drafts-dir DIR] [--draft NAME] [--project DIR] [--title T] [--summary S] [--to-ticket REF]`:
/// files a draft review in Hot Sheet with no UI (a new ticket, or the existing ticket `--to-ticket`
/// names), through the same `ReviewSession` rules and `DraftSubmitter` as the session window, and
/// prints one JSON object. Used by scripts/app-e2e.sh.
/// Exit codes: 0 submitted, 2 bad arguments / no draft / the review has issues, 3 Hot Sheet not
/// ready, 5 submitting failed (the draft is kept). Spec: docs/07-review-session.md §7.8.
@MainActor
enum HeadlessSubmit {
    struct Success: Encodable {
        var status = "submitted"
        var slug: String
        var ticketFile: String?
        var storePath: String
        var title: String
        var mediaCount: Int
        var annotationCount: Int
        var draftDirectory: String
        var draftRemoved: Bool
        var addedToExistingTicket: Bool
        var ticketTitle: String?
        /// Part of the review was added (`--exclude`): the draft keeps this many captures.
        var remainingCaptures: Int?
        /// A ticket an earlier failed New ticket try created and left behind (not deleted).
        var abandonedTicket: String?
    }

    struct Failure: Encodable, Error {
        var status = "error"
        var error: String
        var message: String
        var issues: [String]?
        var createdTicket: String?
        var attachedTo: String?
        /// Set when some files were attached before the attach failed (the retry attaches the rest).
        var partlyAttached: Bool?
        var draftDirectory: String?
    }

    /// The parsed command, its store, and the draft to file; or the failure to print.
    private static func prepare(_ arguments: [String]) -> Result<(SubmitCommand, ReviewDraftStore, ReviewDraft), Failure> {
        let command: SubmitCommand
        do {
            guard let parsed = try SubmitCommand.parse(arguments) else {
                return .failure(Failure(error: "invalidArguments", message: "missing --submit"))
            }
            command = parsed
        } catch {
            return .failure(Failure(error: "invalidArguments", message: String(describing: error)))
        }
        let store = ReviewDraftStore(root: command.draftsDirectory ?? AppSettings.draftsDirectory())
        do {
            if let name = command.draft {
                return try .success((command, store, store.load(store.root.appendingPathComponent(name, isDirectory: true))))
            }
            guard let current = try store.current() else {
                return .failure(Failure(error: "noDraft", message: "There is no current draft review."))
            }
            return .success((command, store, current))
        } catch {
            return .failure(Failure(error: "noDraft", message: ReviewSubmitter.describe(error)))
        }
    }

    static func run(arguments: [String]) -> Int32 {
        let command: SubmitCommand, store: ReviewDraftStore, draft: ReviewDraft
        switch prepare(arguments) {
        case let .success(prepared): (command, store, draft) = prepared
        case let .failure(failure): return fail(failure, code: 2)
        }

        let target = AppSettings.currentStatus()
        var session = ReviewSession(
            directory: draft.directory,
            bundle: draft.bundle,
            target: target,
            missingFiles: Set(
                draft.bundle.media.filter { !FileManager.default.fileExists(atPath: draft.mediaURL($0).path) }
                    .map(\.filename)
            )
        )
        session.edit(title: command.title, summary: command.summary)
        let path = draft.directory.path
        if let problem = target.problem {
            return fail(Failure(error: "hotSheetUnavailable", message: problem, draftDirectory: path), code: 3)
        }
        if let reference = command.toTicket {
            // The same lookup the window runs; its issues block submitting like any other.
            session.setDestination(.existingTicket)
            session.editTicket(reference)
            if let query = session.pendingLookup, let cli = target.cliPath {
                session.resolveLookup(query, query.run(cliPath: cli))
            }
            do {
                try session.setSelection(command.selection(in: session.bundle))
            } catch {
                return fail(Failure(error: "invalidArguments", message: String(describing: error), draftDirectory: path), code: 2)
            }
        }
        return submit(&session, store: store, target: target)
    }

    private static func submit(_ session: inout ReviewSession, store: ReviewDraftStore, target: HotSheetStatus) -> Int32 {
        let path = session.directory.path
        guard session.beginSubmit(), let cli = target.cliPath, let storePath = target.storePath else {
            let issues = session.issues.map { $0.message(in: session.bundle) }
            return fail(
                Failure(error: "invalidReview", message: "The review can't be submitted yet.", issues: issues, draftDirectory: path),
                code: 2
            )
        }
        let submitter = DraftSubmitter(
            store: store,
            client: HotSheetCLIClient(executable: URL(fileURLWithPath: cli), storePath: URL(fileURLWithPath: storePath)),
            storePath: URL(fileURLWithPath: storePath)
        )
        let existing = session.existingTicket
        do {
            let review = try submitter.submit(
                session.directory, title: session.bundle.title, summary: session.bundle.summary, into: existing,
                selection: session.selection
            ) { session.advance($0) }
            session.finish(.success(review))
            print(HeadlessCapture.json(Success(
                slug: review.ticket.slug,
                ticketFile: review.ticket.file,
                storePath: review.storePath,
                title: review.title,
                mediaCount: review.mediaCount,
                annotationCount: review.annotationCount,
                draftDirectory: path,
                draftRemoved: review.draftRemoved,
                addedToExistingTicket: review.addedToExistingTicket,
                ticketTitle: review.ticketTitle,
                remainingCaptures: review.remainingCaptures,
                abandonedTicket: review.abandonedTicket
            )))
            return 0
        } catch {
            session.finish(.failure(error))
            return fail(
                Failure(
                    error: "submitFailed", message: error.message, createdTicket: error.createdTicket,
                    attachedTo: error.attachedTo, partlyAttached: error.partlyAttached ? true : nil, draftDirectory: path
                ),
                code: 5
            )
        }
    }

    private static func fail(_ failure: Failure, code: Int32) -> Int32 {
        print(HeadlessCapture.json(failure))
        return code
    }
}
