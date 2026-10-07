import AppKit
import Combine
import UXReviewKit

extension Notification.Name {
    /// Posted (object: the draft directory URL) after a capture is added to or removed from a
    /// draft, so an open editor and session window on that draft catch up.
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

    /// The player while a video plays (docs/06 §6.10); nil when paused.
    @Published private(set) var playback: VideoPlayback?
    private var playbackTimer: Timer?

    /// Opens the Submit Review window for this draft (docs/07 §7.1). Set by the editor window;
    /// the tool bar shows **Submit Review…** only when it is.
    var submitReview: (() -> Void)?
    /// Chooses images or movies to add to this draft (docs/04 §4.12.2). Set by the editor
    /// window; the tool bar shows **Add Media…** only when it is.
    var addMedia: (() -> Void)?
    /// Asks before removing a capture from the review (docs/06 §6.7). Set by the editor window;
    /// the media strip offers **Remove from Review…** only when it is.
    var confirmRemoval: ((MediaItem) -> Void)?

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
    /// Any change pauses playback first, so edits, gestures, and scrubbing act on a still frame.
    func mutate(_ change: (inout AnnotationEditor) -> Void) {
        pause()
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

    /// Auto-scroll while a gesture runs (docs/06 §6.2.1): pans when `pointer` (canvas
    /// coordinates) is near or past an edge, then moves the gesture to the media point now under
    /// the pointer, so the shape follows even while the mouse is still. False when nothing moved.
    @discardableResult
    func autoScrollStep(pointer: CGPoint, elapsed: TimeInterval) -> Bool {
        guard editor.gesture != nil, let media = mediaSize else { return false }
        var moved = false
        zoom { viewport, view, media, _ in moved = viewport.autoScroll(pointer: pointer, elapsed: elapsed, view: view, media: media) }
        guard moved, let layout = viewport.layout(view: canvasSize, media: media) else { return false }
        let point = CGPoint(
            x: (pointer.x - layout.imageRect.minX) / layout.scale,
            y: (pointer.y - layout.imageRect.minY) / layout.scale
        )
        mutate { $0.updateGesture(to: point) }
        return true
    }

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

    // MARK: Playback

    var isPlaying: Bool { playback != nil }

    /// K or the timeline's play button: plays the current video from the playhead (from the start
    /// when it is at the end), or pauses it. Playing moves the playhead, which is navigation, so
    /// it is not undoable and never marks the draft dirty.
    func togglePlayback() {
        if isPlaying { return pause() }
        guard let id = editor.currentMediaId, editor.gesture == nil, editor.timelineDrag == nil,
              let player = session.playback(id) else { return }
        player.play(fromMs: editor.currentTimeMs)
        playback = player
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.playbackTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    /// Stops playback where it is; the playhead stays on the frame showing.
    func pause() {
        guard let player = playback else { return }
        playbackTimer?.invalidate()
        playbackTimer = nil
        playback = nil
        session.editor.setCurrentTime(player.pause())
        revision += 1
    }

    /// Follows the player: the playhead, and with it the visible annotations and the timeline.
    private func playbackTick() {
        guard let player = playback else { return }
        guard player.isPlaying else { return pause() }
        session.editor.setCurrentTime(player.currentMs)
        revision += 1
    }

    /// The current image for `mediaId` (cropped as edited), cached per crop. For a video, the
    /// frame at the playhead (the session caches frames), or the player's frame while playing.
    func image(_ mediaId: String) -> CGImage? {
        if let player = playback, mediaId == editor.currentMediaId, let frame = player.frame() { return frame }
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
        guard editor.isDirty, editor.gesture == nil, editor.timelineDrag == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Saves now (also on window close). Playback keeps going: an autosave from an edit made
    /// just before pressing K must not stop it.
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

    /// Removes a capture from the review after the reviewer confirmed: saves first, deletes its
    /// file and annotations, shows a neighbor, and tells open session windows (`HS2-SSM1E7`).
    func removeCapture(_ mediaId: String) {
        pause()
        do {
            let changes = try session.removeCapture(mediaId)
            for id in changes.removed {
                imageCache[id] = nil
            }
            saveError = nil
            NotificationCenter.default.post(name: .reviewDraftChanged, object: session.directory)
        } catch {
            saveError = "Couldn't remove the capture: \(error)"
        }
        syncViewport()
        revision += 1
    }

    /// Catches up with captures added to or removed from the draft (docs/06 §6.7). Playback of a
    /// removed video stops where it is, without moving the playhead of what shows next.
    private func draftChanged(_ directory: URL) {
        guard directory.standardizedFileURL == session.directory.standardizedFileURL else { return }
        do {
            let playing = isPlaying ? editor.currentMediaId : nil
            let changes = try session.reload()
            guard !changes.isEmpty else { return }
            if let playing, changes.removed.contains(playing), let player = playback {
                playbackTimer?.invalidate()
                playbackTimer = nil
                playback = nil
                _ = player.pause()
            }
            for id in changes.removed {
                imageCache[id] = nil
            }
            syncViewport()
            revision += 1
        } catch {
            saveError = "Couldn't reload the review: \(error)"
        }
    }
}
