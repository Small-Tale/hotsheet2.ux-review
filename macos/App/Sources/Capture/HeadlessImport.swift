import AppKit
import UXReviewKit

/// `UXReview --import FILE… [--drafts-dir DIR] [--new-review]`: adds existing images and movies
/// to the current draft review without any UI and prints a JSON result. Used by
/// scripts/app-e2e.sh. Exit codes: 0 imported, 2 bad arguments or a file that is missing,
/// unsupported, or unreadable (nothing is imported then), 5 the draft couldn't be written.
/// Spec: docs/04-capture.md §4.12.
@MainActor
enum HeadlessImport {
    struct Success: Encodable {
        var status = "imported"
        var draftDirectory: String
        var files: [String]
        var media: [MediaItem]
    }

    static func run(arguments: [String]) async -> Int32 {
        do {
            guard let command = try ImportCommand.parse(arguments) else { return fail("invalidArguments", "missing --import", code: 2) }
            let store = ReviewDraftStore(root: command.draftsDirectory ?? AppSettings.draftsDirectory())
            let (draft, media) = try await MediaImporter.importFiles(command.files, into: store, newReview: command.newReview)
            print(HeadlessCapture.json(Success(
                draftDirectory: draft.directory.path,
                files: media.map { draft.mediaURL($0).path },
                media: media
            )))
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
