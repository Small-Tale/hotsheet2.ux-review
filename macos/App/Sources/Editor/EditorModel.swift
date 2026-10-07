import AppKit
import Combine
import UXReviewKit

extension Notification.Name {
    /// Posted (object: the draft directory URL) after a capture is added to a draft, so an open
    /// editor on that draft picks it up.
    static let reviewDraftChanged = Notification.Name("UXReviewDraftChanged")
}

/// The editor window's observable wrapper around `EditorSession`. Every change goes through
/// `mutate`, which republishes and schedules an autosave. Spec: docs/06-annotation-editor.md.
@MainActor
final class EditorModel: ObservableObject {
    let session: EditorSession
    /// Bumped on every change so SwiftUI and the canvas redraw.
    @Published private(set) var revision = 0
    @Published private(set) var saveError: String?
    /// Asks the inspector to focus the note field (double-click on a shape, Return).
    @Published var focusNoteRequest = 0
    /// Zoom and pan of the canvas (docs/06 §6.2.1); back to fit whenever other media is shown.
    @Published private(set) var viewport = CanvasViewport()
    /// The canvas's size and screen scale, reported by the canvas so tool bar zoom commands
    /// work in the same coordinates.
    private(set) var canvasSize = CGSize(width: 900, height: 700)
    private(set) var backingScale: CGFloat = 2
    private var viewportMediaId: String?

    private var saveTask: Task<Void, Never>?
    private var imageCache: [String: (crop: PixelRect?, image: CGImage?)] = [:]
    private var draftChanges: AnyCancellable?

    static let autosaveDelay: Duration = .milliseconds(600)

    init(session: EditorSession) {
        self.session = session
        viewportMediaId = session.editor.currentMediaId
        draftChanges = NotificationCenter.default.publisher(for: .reviewDraftChanged)
            .compactMap { $0.object as? URL }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] directory in
                MainActor.assumeIsolated { self?.draftChanged(directory) }
            }
    }

    var editor: AnnotationEditor { session.editor }

    /// Applies a change to the editor, redraws, and schedules an autosave once no gesture is running.
    func mutate(_ change: (inout AnnotationEditor) -> Void) {
        change(&session.editor)
        syncViewport()
        revision += 1
        scheduleSave()
    }

    // MARK: Zoom and pan

    /// The current media's size in pixels (as cropped), which the viewport lays out.
    var mediaSize: CGSize? {
        editor.currentFrame.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Where the current media is drawn in a canvas of `size`.
    func layout(in size: CGSize) -> CanvasViewport.Layout? {
        mediaSize.flatMap { viewport.layout(view: size, media: $0) }
    }

    var zoomPercent: Int? { layout(in: canvasSize)?.percent(backingScale: backingScale) }

    func canvasDidResize(_ size: CGSize, backingScale: CGFloat) {
        guard size != canvasSize || backingScale != self.backingScale else { return }
        canvasSize = size
        self.backingScale = backingScale
        // The fit percentage shown in the tool bar follows the size; publish outside layout.
        DispatchQueue.main.async { [weak self] in self?.revision += 1 }
    }

    /// Applies a zoom/pan change in the canvas's coordinates.
    func zoom(_ change: (inout CanvasViewport, _ view: CGSize, _ media: CGSize, _ backingScale: CGFloat) -> Void) {
        guard let media = mediaSize else { return }
        change(&viewport, canvasSize, media, backingScale)
        revision += 1
    }

    func zoomIn(anchor: CGPoint? = nil) { zoom { $0.step(in: true, anchor: anchor, view: $1, media: $2, backingScale: $3) } }
    func zoomOut(anchor: CGPoint? = nil) { zoom { $0.step(in: false, anchor: anchor, view: $1, media: $2, backingScale: $3) } }
    func zoomToFit() { zoom { viewport, _, _, _ in viewport.fit() } }
    func zoomToActualPixels() { zoom { $0.actualPixels(view: $1, media: $2, backingScale: $3) } }

    /// Previews set an exact viewport.
    func setViewport(_ viewport: CanvasViewport) {
        self.viewport = viewport
        revision += 1
    }

    private func syncViewport() {
        guard editor.currentMediaId != viewportMediaId else { return }
        viewportMediaId = editor.currentMediaId
        viewport = CanvasViewport()
    }

    /// The current image for `mediaId` (cropped as edited), cached per crop. For a video, the
    /// frame at the playhead (the session caches frames).
    func image(_ mediaId: String) -> CGImage? {
        if editor.media(mediaId)?.kind == .video { return session.displayImage(mediaId) }
        let crop = editor.document.crops[mediaId]
        if let cached = imageCache[mediaId], cached.crop == crop { return cached.image }
        let image = session.displayImage(mediaId)
        imageCache[mediaId] = (crop, image)
        return image
    }

    /// Switches to `mediaId`, first picking up media added to the draft since the editor opened.
    func show(mediaId: String) {
        if session.editor.media(mediaId) == nil { draftChanged(session.directory) }
        mutate { $0.show(mediaId: mediaId) }
    }

    func scheduleSave() {
        saveTask?.cancel()
        guard editor.isDirty, editor.gesture == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Saves now (also on window close).
    func save() {
        saveTask?.cancel()
        guard editor.isDirty else { return }
        do {
            try session.save()
            saveError = nil
        } catch {
            saveError = "Couldn't save: \(error)"
        }
        revision += 1
    }

    private func draftChanged(_ directory: URL) {
        guard directory.standardizedFileURL == session.directory.standardizedFileURL else { return }
        do {
            if try !session.reload().isEmpty {
                syncViewport()
                revision += 1
            }
        } catch {
            saveError = "Couldn't reload the review: \(error)"
        }
    }
}
