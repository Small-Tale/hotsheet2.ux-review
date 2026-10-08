import Foundation
import UXReviewKit

/// `UXReview --annotate SCRIPT.json [--drafts-dir DIR] [--draft NAME] [--render-dir DIR]`:
/// runs an editing script through the real editor and save path, prints one JSON object, and
/// optionally writes each media item with its annotations drawn on. Used by scripts/app-e2e.sh.
/// Exit codes: 0 annotated, 2 bad arguments or script, 3 no draft, 5 failed.
/// Spec: docs/06-annotation-editor.md §6.9.
@MainActor
enum HeadlessAnnotate {
    struct Row: Encodable {
        var number: Int
        var id: String
        var mediaId: String
        var type: String
        var intents: [Intent]
        var note: String
        /// Video only; omitted for the whole clip. In the clip as trimmed.
        var timeRange: TimeRange?
        /// Entirely outside the crop or trim: kept in the draft, left out when submitting (HS2-71SSJG).
        var outside: Bool
    }

    struct Success: Encodable {
        var status = "annotated"
        var draftDirectory: String
        var messages: [String]
        var media: [MediaItem]
        /// The capture showing when the script ended, and its playhead (0 for an image).
        var currentMediaId: String?
        var currentTimeMs: Int
        /// The media strip's selection when the script ended, in strip order (docs/06 §6.7.2).
        var selectedMediaIds: [String]
        var annotations: [Row]
        var rendered: [String]
    }

    static func run(arguments: [String]) -> Int32 {
        let command: AnnotateCommand
        let script: EditorScript
        do {
            guard let parsed = try AnnotateCommand.parse(arguments) else { return fail("invalidArguments", "missing --annotate", code: 2) }
            command = parsed
            script = try EditorScript.parse(Data(contentsOf: command.script))
        } catch {
            return fail("invalidArguments", String(describing: error), code: 2)
        }
        let store = ReviewDraftStore(root: command.draftsDirectory ?? AppSettings.draftsDirectory())
        do {
            let directory: URL
            if let name = command.draft {
                directory = store.root.appendingPathComponent(name, isDirectory: true)
            } else if let current = try store.current() {
                directory = current.directory
            } else {
                return fail("noDraft", "There is no current draft review to annotate.", code: 3)
            }
            let session = try EditorSession(store: store, directory: directory)
            let messages: [String]
            do {
                messages = try script.run(on: session)
            } catch let error as EditorScriptError {
                return fail("invalidScript", error.description, code: 2)
            }
            var rendered: [String] = []
            if let renderDirectory = command.renderDirectory {
                try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
                for item in session.editor.bundle.media {
                    guard let image = session.renderAnnotated(item.id) else { continue }
                    let url = renderDirectory.appendingPathComponent("\((item.filename as NSString).deletingPathExtension)-annotated.png")
                    try ImageFiles.writePNG(image, to: url)
                    rendered.append(url.path)
                }
            }
            let bundle = session.editor.bundle
            print(HeadlessCapture.json(Success(
                draftDirectory: directory.path,
                messages: messages,
                media: bundle.media,
                currentMediaId: session.editor.currentMediaId,
                currentTimeMs: session.editor.currentTimeMs,
                selectedMediaIds: session.editor.selectedMediaIds,
                annotations: bundle.annotations.enumerated().map { index, annotation in
                    Row(
                        number: index + 1, id: annotation.id, mediaId: annotation.mediaId, type: annotation.shape.kind,
                        intents: annotation.effectiveIntents, note: annotation.note, timeRange: annotation.timeRange,
                        outside: session.editor.isOutsideEdit(annotation)
                    )
                },
                rendered: rendered
            )))
            return 0
        } catch {
            return fail("failed", String(describing: error), code: 5)
        }
    }

    private static func fail(_ error: String, _ message: String, code: Int32) -> Int32 {
        print(HeadlessCapture.json(HeadlessCapture.Failure(error: error, message: message)))
        return code
    }
}
