import AppKit
import UXReviewKit

/// `UXReview --submit [--drafts-dir DIR] [--draft NAME] [--project DIR] [--title T] [--summary S]`:
/// files a draft review in Hot Sheet with no UI, through the same `ReviewSession` rules and
/// `DraftSubmitter` as the session window, and prints one JSON object. Used by scripts/app-e2e.sh.
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
    }

    struct Failure: Encodable, Error {
        var status = "error"
        var error: String
        var message: String
        var issues: [String]?
        var createdTicket: String?
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
        do {
            let review = try submitter
                .submit(draft.directory, title: session.bundle.title, summary: session.bundle.summary) { session.advance($0) }
            session.finish(.success(review))
            print(HeadlessCapture.json(Success(
                slug: review.ticket.slug,
                ticketFile: review.ticket.file,
                storePath: review.storePath,
                title: review.title,
                mediaCount: review.mediaCount,
                annotationCount: review.annotationCount,
                draftDirectory: path,
                draftRemoved: review.draftRemoved
            )))
            return 0
        } catch {
            session.finish(.failure(error))
            return fail(
                Failure(error: "submitFailed", message: error.message, createdTicket: error.createdTicket, draftDirectory: path),
                code: 5
            )
        }
    }

    private static func fail(_ failure: Failure, code: Int32) -> Int32 {
        print(HeadlessCapture.json(failure))
        return code
    }
}
