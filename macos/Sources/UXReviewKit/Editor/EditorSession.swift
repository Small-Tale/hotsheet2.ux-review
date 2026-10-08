import AVFoundation
import CoreGraphics
import Foundation

/// One open annotation editor on a draft review: the `AnnotationEditor` state plus the files
/// behind it. It loads the images and video frames, and saves the bundle through
/// `ReviewDraftStore.update` (so captures added meanwhile are kept). The editor window and the
/// headless `--annotate` mode share it. Spec: docs/06-annotation-editor.md §6.6, §6.7, and §6.10.
///
/// Crops and trims are not destructive while the review is a draft (`HS2-71SSJG`): capture files
/// are never rewritten. `review.json` keeps each file's own size and duration, with annotations
/// in its coordinates and times, and `edits.json` (`DraftEdits`) records each crop and trim. The
/// editor works in crop and trim coordinates (`EditProjection.editing`); saving maps back
/// exactly. Submitting applies the crop and trim (`SubmissionStaging`).
public final class EditorSession {
    /// Where drafts made before `HS2-71SSJG` kept untouched originals (`DraftEdits.migrateLegacy`).
    public static let originalsDirectory = "originals"

    /// When each video's expected frame rate (for ← / → frame steps, docs/06 §6.10) is read from
    /// its movie.
    public enum FrameRateLoading: Sendable {
        /// While the session opens or picks up a capture, blocking (headless runs, previews, tests).
        case immediately
        /// In the background (`HS2-F999CM`): a movie without a recorded rate has its whole sample
        /// table read, which takes a while for a long one. Frame steps use 30 fps until the rate
        /// arrives, then the movie's. The session must then be used on the main actor, where the
        /// rate is applied.
        case inBackground
    }

    public var editor: AnnotationEditor
    public let directory: URL
    public let store: ReviewDraftStore
    /// Images as their files hold them (uncropped), loaded once.
    private var baseImages: [String: CGImage] = [:]
    private var frames: [String: VideoFrames] = [:]
    /// Each annotation as last read from or written to disk (file coordinates and times). Saving
    /// keeps these exactly for annotations the reviewer didn't change, so mapping into a crop and
    /// back never drifts by rounding.
    private var stored: [String: Annotation] = [:]
    public let frameRateLoading: FrameRateLoading
    /// Background frame-rate reads in flight, by media id, with a token so a result never lands
    /// on a capture removed (or re-added under the same id) meanwhile.
    private var frameRateLoads: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    public init(
        store: ReviewDraftStore,
        directory: URL,
        mediaId: String? = nil,
        frameRateLoading: FrameRateLoading = .immediately
    ) throws {
        self.store = store
        self.directory = directory
        self.frameRateLoading = frameRateLoading
        try store.migrateLegacyEdits(directory)
        let bundle = try store.load(directory).bundle
        let (crops, trims) = DraftEdits.load(from: directory).byMediaId(in: bundle)
        var priors: [String: PriorCrop] = [:]
        var priorTrims: [String: PriorTrim] = [:]
        for item in bundle.media {
            if let crop = crops[item.id] { priors[item.id] = PriorCrop(originalSize: EditProjection.size(of: item), crop: crop) }
            if let trim = trims[item.id], let duration = item.durationMs {
                priorTrims[item.id] = PriorTrim(originalDurationMs: duration, trim: trim)
            }
        }
        editor = AnnotationEditor(
            bundle: EditProjection.editing(bundle, crops: crops, trims: trims),
            mediaId: mediaId,
            originals: priors,
            trims: priorTrims
        )
        stored = Dictionary(bundle.annotations.map { ($0.id, $0) }) { first, _ in first }
        loadFrameGrids(bundle.media.map(\.id))
    }

    deinit {
        for load in frameRateLoads.values {
            load.task.cancel()
        }
    }

    /// Reads each video's expected frame rate from its movie, for ← / → frame steps (docs/06
    /// §6.10): now, or in the background per `frameRateLoading`.
    private func loadFrameGrids(_ ids: [String]) {
        for id in ids {
            guard let item = editor.media(id), item.kind == .video else { continue }
            let url = fileURL(item)
            switch frameRateLoading {
            case .immediately:
                editor.setFrameRate(VideoTrim.frameRate(of: url), for: id)
            case .inBackground:
                let token = UUID()
                let reference = Reference(self)
                let task = Task.detached(priority: .userInitiated) {
                    let rate = await VideoTrim.loadFrameRate(of: url)
                    await MainActor.run { reference.session?.finishFrameRate(rate, for: id, token: token) }
                }
                frameRateLoads[id]?.task.cancel()
                frameRateLoads[id] = (token, task)
            }
        }
    }

    /// Applies a background read, unless the capture was removed or reloaded meanwhile.
    private func finishFrameRate(_ rate: Double?, for id: String, token: UUID) {
        guard frameRateLoads[id]?.token == token else { return }
        frameRateLoads[id] = nil
        editor.setFrameRate(rate, for: id)
    }

    /// Waits until every background frame-rate read started so far has been applied.
    @MainActor
    public func frameRatesLoaded() async {
        while let (id, load) = frameRateLoads.first {
            await load.task.value
            // Normally applied (and cleared) by now; never wait on the same read twice.
            if frameRateLoads[id]?.token == load.token { frameRateLoads[id] = nil }
        }
    }

    /// Whether a background frame-rate read is still in flight for `mediaId`.
    public func isLoadingFrameRate(_ mediaId: String) -> Bool { frameRateLoads[mediaId] != nil }

    /// A weak reference to the session for a background task; the session is only touched on the
    /// main actor (`FrameRateLoading.inBackground`).
    private final class Reference: @unchecked Sendable {
        weak var session: EditorSession?
        init(_ session: EditorSession) { self.session = session }
    }

    public func fileURL(_ item: MediaItem) -> URL { directory.appendingPathComponent(item.filename) }

    /// What the canvas shows for `mediaId`: the image with its current crop (or, with
    /// `uncropped`, its whole original, as the Crop tool shows it), or the video frame at `atMs`
    /// into the clip as trimmed (default: the playhead for the current media, else the first
    /// frame). Nil when the file can't be read.
    public func displayImage(_ mediaId: String, atMs: Int? = nil, uncropped: Bool = false) -> CGImage? {
        guard let item = editor.media(mediaId) else { return nil }
        let base = item.kind == .video ? frame(item, atMs: atMs ?? time(of: mediaId)) : baseImage(item)
        guard let base else { return nil }
        return uncropped ? base : cropped(base, for: mediaId)
    }

    /// `image` (a whole frame or image of `mediaId`) cut to its crop, as the canvas simulates it
    /// (`HS2-M03YP2`: video frames, playing or not). A frame of another size than the original
    /// is cut proportionally.
    public func cropped(_ image: CGImage, for mediaId: String) -> CGImage {
        guard let crop = editor.document.crops[mediaId], let size = editor.originalSize(of: mediaId) else { return image }
        let scaleX = Double(image.width) / Double(max(size.width, 1))
        let scaleY = Double(image.height) / Double(max(size.height, 1))
        let rect = CGRect(
            x: Double(crop.x) * scaleX, y: Double(crop.y) * scaleY,
            width: Double(crop.width) * scaleX, height: Double(crop.height) * scaleY
        ).integral
        return image.cropping(to: rect) ?? image
    }

    /// The image the canvas draws for the current media: uncropped while the Crop tool shows the
    /// original (`AnnotationEditor.showsOriginal`), else as cropped.
    public func canvasImage() -> CGImage? {
        editor.currentMediaId.flatMap { displayImage($0, uncropped: editor.showsOriginal) }
    }

    /// The annotations the canvas draws for the current media: those showing (`renderItems`), or,
    /// while the Crop tool shows the original, all those showing at the playhead mapped into the
    /// original (`AnnotationEditor.annotationsInOriginal`).
    public func canvasItems() -> [AnnotationRenderer.Item] {
        guard let id = editor.currentMediaId else { return [] }
        guard editor.showsOriginal else { return renderItems(id) }
        return editor.annotationsInOriginal(on: id).compactMap { annotation in
            editor.number(of: annotation.id).map { AnnotationRenderer.Item(number: $0, annotation: annotation) }
        }
    }

    /// Writes the bundle (in the files' own coordinates) and `edits.json`. It first catches up
    /// with the draft (`reload`), so a capture removed meanwhile is never written back. Returns
    /// how the editor's media changed (captures added or removed meanwhile).
    @discardableResult
    public func save() throws -> MediaChanges {
        let before = try reload()
        let persisted = persistable()
        let saved = try store.update(directory) { disk in
            let files = Dictionary(persisted.bundle.media.map { ($0.id, $0) }) { first, _ in first }
            for index in disk.media.indices {
                if let item = files[disk.media[index].id] {
                    disk.media[index].pixelWidth = item.pixelWidth
                    disk.media[index].pixelHeight = item.pixelHeight
                    disk.media[index].durationMs = item.durationMs
                }
            }
            // A capture removed between the reload above and this write keeps its annotations out.
            let present = Set(disk.media.map(\.id))
            disk.annotations = persisted.bundle.annotations.filter { present.contains($0.mediaId) }
            var edits = DraftEdits.load(from: directory)
            let names = Set(disk.media.map(\.filename))
            edits.crops = persisted.edits.crops.filter { names.contains($0.key) }
            edits.trims = persisted.edits.trims.filter { names.contains($0.key) }
            try edits.save(to: directory)
        }
        stored = Dictionary(saved.bundle.annotations.map { ($0.id, $0) }) { first, _ in first }
        editor.markSaved()
        let after = apply(editor.syncMedia(with: saved.bundle))
        return MediaChanges(added: before.added + after.added, removed: before.removed + after.removed)
    }

    /// The editor's document in the files' own space: media at their files' sizes and durations,
    /// annotations mapped out of their crop and trim, and the crops and trims by filename.
    func persistable() -> (bundle: ReviewBundle, edits: DraftEdits) {
        let document = editor.document
        var bundle = document.bundle
        var edits = DraftEdits()
        for index in bundle.media.indices {
            let item = bundle.media[index]
            if let size = editor.originalSizes[item.id] {
                bundle.media[index].pixelWidth = size.width
                bundle.media[index].pixelHeight = size.height
            }
            if item.kind == .video, let duration = editor.originalDurations[item.id] { bundle.media[index].durationMs = duration }
            if let crop = document.crops[item.id] { edits.crops[item.filename] = crop }
            if let trim = document.trims[item.id] { edits.trims[item.filename] = trim }
        }
        bundle.annotations = document.bundle.annotations.map { annotation in
            let crop = document.crops[annotation.mediaId]
            let trim = document.trims[annotation.mediaId]
            let size = editor.originalSizes[annotation.mediaId]
            var file = annotation
            if let crop, let size {
                let previous = stored[annotation.id].map(\.shape)
                file.shape = previous.flatMap { EditProjection.shape($0, into: crop, of: size) == annotation.shape ? $0 : nil }
                    ?? EditProjection.shape(annotation.shape, outOf: crop, to: size)
            }
            if let trim, let range = annotation.timeRange { file.timeRange = EditProjection.range(range, outOf: trim) }
            return file
        }
        return (bundle, edits)
    }

    /// Remove from Review in the editor (`HS2-SSM1E7`): saves this session's edits first, so
    /// unsaved work on the other captures is kept, then removes the capture from the draft
    /// (`ReviewDraftStore.removeMedia`: its file, annotations, and crop or trim) and catches up.
    /// The editor then shows a neighboring capture. It can't be undone.
    @discardableResult
    public func removeCapture(_ mediaId: String) throws -> MediaChanges {
        try removeCaptures([mediaId])
    }

    /// Removes several captures at once (the media strip's selection, docs/06 §6.7.2): checks
    /// every id first (an unknown one removes nothing), saves once, removes each in turn, and
    /// catches up. If a removal fails partway, the editor still catches up with what was removed
    /// before the error is thrown. Removing every capture leaves the empty draft, as removing the
    /// last one does.
    @discardableResult
    public func removeCaptures(_ mediaIds: [String]) throws -> MediaChanges {
        var unique: [String] = []
        for id in mediaIds where !unique.contains(id) {
            guard editor.media(id) != nil else { throw ReviewDraftError.unknownMedia(id) }
            unique.append(id)
        }
        guard !unique.isEmpty else { return MediaChanges() }
        try save()
        do {
            for id in unique {
                try store.removeMedia(id, from: directory)
            }
        } catch {
            _ = try? reload()
            throw error
        }
        return try reload()
    }

    /// Catches up with the draft on disk: picks up media captured since the editor opened and
    /// drops media removed from the draft (with its annotations, history, and cached files).
    /// Spec: docs/06-annotation-editor.md §6.7.
    @discardableResult
    public func reload() throws -> MediaChanges {
        try apply(editor.syncMedia(with: store.load(directory).bundle))
    }

    /// Forgets what the session kept for removed media (a later capture may reuse the id).
    private func apply(_ changes: MediaChanges) -> MediaChanges {
        for id in changes.removed {
            baseImages[id] = nil
            frames[id] = nil
            frameRateLoads.removeValue(forKey: id)?.task.cancel()
            editor.setFrameRate(nil, for: id)
        }
        loadFrameGrids(changes.added)
        return changes
    }

    /// The annotations of one media item that show at its time (the playhead for the current
    /// video, else the start), numbered for drawing.
    public func renderItems(_ mediaId: String) -> [AnnotationRenderer.Item] {
        editor.visibleAnnotations(on: mediaId).compactMap { annotation in
            editor.number(of: annotation.id).map { AnnotationRenderer.Item(number: $0, annotation: annotation) }
        }
    }

    /// Where `mediaId` is shown: the playhead for the current media, else the start.
    private func time(of mediaId: String) -> Int { mediaId == editor.currentMediaId ? editor.currentTimeMs : 0 }

    /// The media with its annotations drawn on, as the reviewer sees it (unselected).
    public func renderAnnotated(_ mediaId: String) -> CGImage? {
        guard let image = displayImage(mediaId) else { return nil }
        return AnnotationRenderer.render(image: image, items: renderItems(mediaId))
    }

    // MARK: Files

    private func baseImage(_ item: MediaItem) -> CGImage? {
        if let image = baseImages[item.id] { return image }
        let image = try? ImageFiles.loadImage(at: fileURL(item))
        baseImages[item.id] = image
        return image
    }

    /// A player for `mediaId` as currently trimmed. Nil for images. Make a new one after the
    /// trim changes.
    public func playback(_ mediaId: String) -> VideoPlayback? {
        guard let item = editor.media(mediaId), item.kind == .video, let duration = item.durationMs else { return nil }
        return VideoPlayback(url: fileURL(item), offsetMs: editor.document.trims[item.id]?.startMs ?? 0, durationMs: duration)
    }

    private func frame(_ item: MediaItem, atMs millis: Int) -> CGImage? {
        let url = fileURL(item)
        if frames[item.id]?.url != url { frames[item.id] = VideoFrames(url: url) }
        return frames[item.id]?.frame(atMs: (editor.document.trims[item.id]?.startMs ?? 0) + millis)
    }
}
