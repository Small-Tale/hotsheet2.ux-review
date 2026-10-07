import AVFoundation
import CoreGraphics
import Foundation

/// One open annotation editor on a draft review: the `AnnotationEditor` state plus the files
/// behind it. It loads the images and video frames, saves the bundle through
/// `ReviewDraftStore.update` (so captures added meanwhile are kept), and writes cropped images
/// and trimmed movies. The editor window and the headless `--annotate` mode share it.
/// Spec: docs/06-annotation-editor.md §6.6, §6.7, and §6.10.
///
/// Crops and trims stay undoable after saving: each file is rewritten from the session's base
/// file, cropped or trimmed as currently edited. The first time a capture is ever cropped or
/// trimmed, its untouched file is kept under `originals/` in the draft (never submitted), and
/// `originals/crops.json` records the crop or trim relative to it. A later session then uses the
/// original as the base, with that edit already applied, so Restore Original brings it back
/// (`OriginalsIndex`).
public final class EditorSession {
    public static let originalsDirectory = "originals"

    public var editor: AnnotationEditor
    public let directory: URL
    let store: ReviewDraftStore
    /// Image files as they were when the session opened, loaded before anything overwrites them.
    private var baseImages: [String: CGImage] = [:]
    private var savedCrops: [String: PixelRect] = [:]
    private var savedTrims: [String: TimeRange] = [:]
    /// Media whose base is their `originals/` copy (crops and trims are relative to it).
    private var tracked: Set<String> = []
    private var frames: [String: VideoFrames] = [:]
    /// Copies of movies taken before this session first rewrote them, for movies whose base is
    /// the file as found (an untrusted original exists, so the file can't become the original).
    private var sessionBases: [String: URL] = [:]

    public init(store: ReviewDraftStore, directory: URL, mediaId: String? = nil) throws {
        self.store = store
        self.directory = directory
        let bundle = try store.load(directory).bundle
        let originals = directory.appendingPathComponent(Self.originalsDirectory, isDirectory: true)
        let index = OriginalsIndex.load(from: originals)
        var priors: [String: PriorCrop] = [:]
        for item in bundle.media where item.kind == .image {
            let size = (try? ImageFiles.pixelSize(of: originals.appendingPathComponent(item.filename)))
                .map { PixelRect(x: 0, y: 0, width: $0.width, height: $0.height) }
            if let prior = index.prior(
                filename: item.filename, originalSize: size, currentWidth: item.pixelWidth, currentHeight: item.pixelHeight
            ) {
                priors[item.id] = prior
            }
        }
        var trims: [String: PriorTrim] = [:]
        for item in bundle.media where item.kind == .video {
            let exists = FileManager.default.fileExists(atPath: originals.appendingPathComponent(item.filename).path)
            if let prior = index.priorTrim(filename: item.filename, originalExists: exists, currentDurationMs: item.durationMs) {
                trims[item.id] = prior
            }
        }
        tracked = Set(priors.keys).union(trims.keys)
        editor = AnnotationEditor(bundle: bundle, mediaId: mediaId, originals: priors, trims: trims)
        savedCrops = editor.document.crops
        savedTrims = editor.document.trims
    }

    deinit {
        for url in sessionBases.values {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var originalsURL: URL { directory.appendingPathComponent(Self.originalsDirectory, isDirectory: true) }

    /// True when Reset Crop brings back the untouched original: the base is the `originals/`
    /// copy, or there is no copy yet (the file itself is untouched). False only for an original
    /// kept before crops were recorded, where Reset Crop returns to the file as this session found it.
    public func resetRestoresOriginal(_ mediaId: String) -> Bool {
        guard let item = editor.media(mediaId) else { return false }
        return tracked.contains(mediaId) || !FileManager.default.fileExists(atPath: originalsURL.appendingPathComponent(item.filename).path)
    }

    public func fileURL(_ item: MediaItem) -> URL { directory.appendingPathComponent(item.filename) }

    /// What the canvas shows for `mediaId`: the image with its current crop, or the video frame
    /// at `atMs` into the clip as trimmed (default: the playhead for the current media, else the
    /// first frame). Nil when the file can't be read.
    public func displayImage(_ mediaId: String, atMs: Int? = nil) -> CGImage? {
        guard let item = editor.media(mediaId) else { return nil }
        if item.kind == .video { return frame(item, atMs: atMs ?? time(of: mediaId)) }
        guard let base = baseImage(item) else { return nil }
        guard let crop = editor.document.crops[mediaId] else { return base }
        return ImageCrop.apply(crop, to: base)
    }

    /// Writes changed crops and the bundle. Returns the ids of media that were captured while the
    /// editor was open (now part of the editor too).
    @discardableResult
    public func save() throws -> [String] {
        let document = editor.document
        for item in document.bundle.media where item.kind == .image && document.crops[item.id] != savedCrops[item.id] {
            try writeCrop(item, crop: document.crops[item.id])
            savedCrops[item.id] = document.crops[item.id]
        }
        for item in document.bundle.media where item.kind == .video && document.trims[item.id] != savedTrims[item.id] {
            try writeTrim(item, trim: document.trims[item.id])
            savedTrims[item.id] = document.trims[item.id]
        }
        let saved = try store.update(directory) { disk in
            let edited = Dictionary(document.bundle.media.map { ($0.id, $0) }) { first, _ in first }
            for index in disk.media.indices {
                if let item = edited[disk.media[index].id] {
                    disk.media[index].pixelWidth = item.pixelWidth
                    disk.media[index].pixelHeight = item.pixelHeight
                    disk.media[index].durationMs = item.durationMs
                }
            }
            disk.annotations = document.bundle.annotations
        }
        editor.markSaved()
        return editor.mergeMedia(from: saved.bundle)
    }

    /// Picks up media captured into this draft since the editor opened. Returns the new ids.
    @discardableResult
    public func reload() throws -> [String] {
        try editor.mergeMedia(from: store.load(directory).bundle)
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
        let url = tracked.contains(item.id) ? originalsURL.appendingPathComponent(item.filename) : fileURL(item)
        let image = try? ImageFiles.loadImage(at: url)
        baseImages[item.id] = image
        return image
    }

    /// The movie that trims are relative to: the kept original, a session copy, or the file.
    private func baseMovie(_ item: MediaItem) -> URL {
        if tracked.contains(item.id) { return originalsURL.appendingPathComponent(item.filename) }
        return sessionBases[item.id] ?? fileURL(item)
    }

    /// A player for `mediaId` as currently trimmed, playing the same movie the frames come from.
    /// Nil for images. Make a new one after the trim changes.
    public func playback(_ mediaId: String) -> VideoPlayback? {
        guard let item = editor.media(mediaId), item.kind == .video, let duration = item.durationMs else { return nil }
        return VideoPlayback(url: baseMovie(item), offsetMs: editor.document.trims[item.id]?.startMs ?? 0, durationMs: duration)
    }

    private func frame(_ item: MediaItem, atMs millis: Int) -> CGImage? {
        let base = baseMovie(item)
        if frames[item.id]?.url != base { frames[item.id] = VideoFrames(url: base) }
        return frames[item.id]?.frame(atMs: (editor.document.trims[item.id]?.startMs ?? 0) + millis)
    }

    private func writeTrim(_ item: MediaItem, trim: TimeRange?) throws {
        let url = fileURL(item)
        let originals = originalsURL
        let original = originals.appendingPathComponent(item.filename)
        if !tracked.contains(item.id), sessionBases[item.id] == nil {
            if !FileManager.default.fileExists(atPath: original.path) {
                // First trim ever: the base is the untouched file, so from now on it is the original.
                try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: original)
                tracked.insert(item.id)
            } else {
                // An original this session can't trust: never overwrite it; keep the file as found.
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("uxreview-base-\(UUID().uuidString).\(url.pathExtension)")
                try FileManager.default.copyItem(at: url, to: copy)
                sessionBases[item.id] = copy
            }
        }
        let base = baseMovie(item)
        if let trim {
            try VideoTrim.export(base, range: trim, to: url)
        } else {
            try VideoTrim.restore(base, to: url)
        }
        var index = OriginalsIndex.load(from: originals)
        let length = editor.originalDurations[item.id] ?? item.durationMs ?? 0
        let kept = trim ?? TimeRange(startMs: 0, endMs: length)
        index.trims[item.filename] = tracked.contains(item.id)
            ? TrimRecord(startMs: kept.startMs, endMs: kept.endMs, originalDurationMs: length)
            : nil
        try index.save(to: originals)
    }

    private func writeCrop(_ item: MediaItem, crop: PixelRect?) throws {
        guard let base = baseImage(item) else { throw ImageFileError.unreadable(fileURL(item)) }
        let url = fileURL(item)
        let originals = originalsURL
        let original = originals.appendingPathComponent(item.filename)
        if !FileManager.default.fileExists(atPath: original.path) {
            // First crop ever: the base is the untouched file, so from now on it is the original.
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: original)
            tracked.insert(item.id)
        }
        guard let pixels = crop.map({ ImageCrop.apply($0, to: base) }) ?? base else { throw ImageFileError.cannotWrite(url) }
        try ImageFiles.writePNG(pixels, to: url)
        // Record the crop relative to the original, or forget it when the base isn't the original
        // (an original kept before crops were recorded, whose offset is unknown).
        var index = OriginalsIndex.load(from: originals)
        index.crops[item.filename] = tracked.contains(item.id)
            ? crop ?? PixelRect(x: 0, y: 0, width: base.width, height: base.height)
            : nil
        try index.save(to: originals)
    }
}
