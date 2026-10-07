import AppKit
import UXReviewKit

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
