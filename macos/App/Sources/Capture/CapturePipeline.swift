import AppKit
import UXReviewKit

/// The result of one capture: the file now lives in the draft review.
struct CaptureOutcome {
    var draft: ReviewDraft
    var media: MediaItem

    var fileURL: URL { draft.mediaURL(media) }
}

/// Capture → context → file → draft review. Shared by the menu bar UI and headless mode; target
/// picking and countdowns happen before this runs.
@MainActor
struct CapturePipeline {
    let backend: CaptureBackend
    let store: ReviewDraftStore

    func screenshot(_ source: CaptureSource) async throws -> CaptureOutcome {
        // Context first: it describes the screen at the moment of capture.
        var context = CaptureContextProvider.context(for: source, displayScale: nil)
        let captured = try await backend.screenshot(source)
        context.displayScale = captured.displayScale > 0 ? captured.displayScale : nil
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("uxreview-\(UUID().uuidString).png")
        do {
            try ImageFiles.writePNG(captured.image, to: temporary)
            let (draft, media) = try store.add(DraftCapture(
                fileURL: temporary,
                kind: .image,
                pixelWidth: captured.image.width,
                pixelHeight: captured.image.height,
                capturedAt: Date(),
                context: context
            ))
            return CaptureOutcome(draft: draft, media: media)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw CaptureFailure.failed(String(describing: error))
        }
    }
}

extension AppSettings {
    /// Where draft reviews are kept: `UXREVIEW_DRAFTS_DIR` when set (tests), else Application Support.
    static func draftsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["UXREVIEW_DRAFTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ReviewDraftStore.defaultRoot
    }
}
