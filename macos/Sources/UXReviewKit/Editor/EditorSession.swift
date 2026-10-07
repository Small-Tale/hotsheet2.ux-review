import AVFoundation
import CoreGraphics
import Foundation

/// One open annotation editor on a draft review: the `AnnotationEditor` state plus the files
/// behind it. It loads the images, saves the bundle through `ReviewDraftStore.update` (so
/// captures added meanwhile are kept), and writes cropped images. The editor window and the
/// headless `--annotate` mode share it. Spec: docs/06-annotation-editor.md §6.6–6.7.
///
/// Crops stay undoable after saving: each image file is rewritten from the session's base
/// image, cropped by the current crop. The first time a capture is ever cropped, its untouched
/// file is kept under `originals/` in the draft (never submitted), and `originals/crops.json`
/// records the crop relative to it. A later session then uses the original as the base, with
/// that crop already applied, so Reset Crop restores the original (`OriginalsIndex`).
public final class EditorSession {
    public static let originalsDirectory = "originals"

    public var editor: AnnotationEditor
    public let directory: URL
    let store: ReviewDraftStore
    /// Image files as they were when the session opened, loaded before anything overwrites them.
    private var baseImages: [String: CGImage] = [:]
    private var posters: [String: CGImage] = [:]
    private var savedCrops: [String: PixelRect] = [:]
    /// Images whose base is their `originals/` copy (crops are relative to it).
    private var tracked: Set<String> = []

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
        tracked = Set(priors.keys)
        editor = AnnotationEditor(bundle: bundle, mediaId: mediaId, originals: priors)
        savedCrops = editor.document.crops
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

    /// What the canvas shows for `mediaId`: the image with its current crop, or a video's first
    /// frame. Nil when the file can't be read.
    public func displayImage(_ mediaId: String) -> CGImage? {
        guard let item = editor.media(mediaId) else { return nil }
        if item.kind == .video { return poster(item) }
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
        let saved = try store.update(directory) { disk in
            let edited = Dictionary(document.bundle.media.map { ($0.id, $0) }) { first, _ in first }
            for index in disk.media.indices {
                if let item = edited[disk.media[index].id] {
                    disk.media[index].pixelWidth = item.pixelWidth
                    disk.media[index].pixelHeight = item.pixelHeight
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

    /// The annotations of one media item, numbered for drawing.
    public func renderItems(_ mediaId: String) -> [AnnotationRenderer.Item] {
        editor.annotations(on: mediaId).compactMap { annotation in
            editor.number(of: annotation.id).map { AnnotationRenderer.Item(number: $0, annotation: annotation) }
        }
    }

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

    private func poster(_ item: MediaItem) -> CGImage? {
        if let image = posters[item.id] { return image }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL(item)))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        let image = try? generator.copyCGImage(at: .zero, actualTime: nil)
        posters[item.id] = image
        return image
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
