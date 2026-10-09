import AppKit
import UXReviewKit

/// The Delete Immediately confirmation (shown when the Trash refuses a discarded review) for
/// `--render-ui-previews`, on a throwaway review with a created ticket. Spec: docs/07 §7.9.
@MainActor
enum DiscardPreviews {
    static func render(to directory: URL) throws -> [URL] {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("uxreview-discard-previews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let store = ReviewDraftStore(root: scratch.appendingPathComponent("Drafts"))
        var draft: ReviewDraft?
        for number in 0 ..< 2 {
            let file = scratch.appendingPathComponent("mock-\(number).png")
            try Data("mock".utf8).write(to: file)
            draft = try store.add(DraftCapture(
                fileURL: file, kind: .image, pixelWidth: 1600, pixelHeight: 1000, capturedAt: Date(),
                context: CaptureContext(appName: "Acme Mail")
            )).draft
        }
        guard let draft else { return [] }
        try store.update(draft.directory) { bundle in
            bundle.title = "Checkout polish"
            bundle.annotations = (0 ..< 3).map {
                Annotation(id: "a\($0)", mediaId: "m1", shape: .insertion(NormPoint(x: 5000, y: 5000)), note: "")
            }
        }
        try store.savePendingSubmission(
            PendingSubmission(storePath: "/s.hs2", ticket: CreatedTicket(slug: "HS-R58EY5"), createdAt: Date()),
            in: draft.directory
        )
        let summary = try store.summary(of: draft.directory)
        let reason = ReviewDraftError.trashFailed(draft.directory, "The volume “Scratch” doesn't have a Trash.").trashRefusal ?? ""
        let alert = DraftDiscarding.deleteAlert(for: summary, reason: reason)
        alert.layout()
        guard let view = alert.window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { throw CaptureFailure.failed("no bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { throw CaptureFailure.failed("render failed") }
        let url = directory.appendingPathComponent("drafts-delete-immediately.png")
        try ImageFiles.writePNG(image, to: url)
        return [url]
    }
}
