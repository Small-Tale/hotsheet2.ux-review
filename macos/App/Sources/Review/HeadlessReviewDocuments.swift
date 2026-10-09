import Foundation
import UXReviewKit

/// `--open-review`, `--save-review`, and `--duplicate-review` (`ReviewDocumentCommand`) with JSON
/// output. Exit codes: 0 done, 2 bad arguments or no such review, 4 something already at the
/// destination (without `--replace`), 5 the operation failed. Spec: docs/07-review-session.md §7.10.
@MainActor
enum HeadlessReviewDocuments {
    struct Done: Encodable {
        /// "opened", "saved", "copied", or "duplicated".
        var status: String
        var draftDirectory: String
        var title: String
        var isUntitled: Bool
        var isCurrent: Bool
        var captureCount: Int
    }

    struct Failure: Encodable {
        var status = "error"
        var error: String
        var message: String
    }

    static func run(arguments: [String]) -> Int32 {
        let command: ReviewDocumentCommand
        do {
            guard let parsed = try ReviewDocumentCommand.parse(arguments) else {
                return fail("invalidArguments", "missing \(ReviewDocumentCommand.flags.joined(separator: " / "))", code: 2)
            }
            command = parsed
        } catch {
            return fail("invalidArguments", String(describing: error), code: 2)
        }
        let store = ReviewDraftStore(
            root: command.draftsDirectory ?? AppSettings.draftsDirectory(),
            trash: DraftTrash.from(environment: ProcessInfo.processInfo.environment)
        )
        let review = command.review(in: store.root)
        do {
            let status: String
            let result: ReviewDraft
            switch command {
            case .open:
                result = try store.open(review)
                try store.makeCurrent(result.directory)
                status = "opened"
            case let .save(_, destination, copy, replace, _):
                let target = URL(fileURLWithPath: destination)
                result = copy
                    ? try store.saveCopy(review, to: target, replacing: replace)
                    : try store.save(review, to: target, replacing: replace)
                status = copy ? "copied" : "saved"
            case .duplicate:
                result = try store.duplicate(review)
                status = "duplicated"
            }
            print(HeadlessCapture.json(Done(
                status: status,
                draftDirectory: result.directory.path,
                title: result.bundle.title,
                isUntitled: store.isUntitled(result.directory),
                isCurrent: store.isCurrent(result.directory),
                captureCount: result.bundle.media.count
            )))
            return 0
        } catch let error as ReviewDraftError {
            switch error {
            case .unreadableDraft, .noSuchDraft: return fail("noReview", error.description, code: 2)
            case .destinationExists: return fail("destinationExists", error.description, code: 4)
            default: return fail("failed", error.description, code: 5)
            }
        } catch {
            return fail("failed", (error as NSError).localizedDescription, code: 5)
        }
    }

    private static func fail(_ error: String, _ message: String, code: Int32) -> Int32 {
        print(HeadlessCapture.json(Failure(error: error, message: message)))
        return code
    }
}
