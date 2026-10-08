import Foundation

/// What gets filed for a draft: its crops and trims applied (`HS2-71SSJG`), then each capture
/// scaled down for the target project's AI tool when `scale` is given (`HS2-PT8PM6`). With
/// nothing cropped, trimmed, or scaled this is the draft itself. Otherwise a hidden `.submission`
/// folder in the draft holds a PNG for each cropped or scaled image, one export (trim and scale
/// together) for each trimmed or scaled movie, and copies of the rest, and the bundle has their
/// filed sizes and annotations clipped to them, those entirely outside left out
/// (`EditProjection.submission`). Annotation coordinates are normalized to the media, so scaling
/// leaves them as they are. Part of a review (a `ReviewSelection` for an existing ticket, §7.2.2)
/// is always staged there, with only its captures and annotations, so the draft's own
/// `review.json` is never overwritten. The draft's files are never changed. Spec:
/// docs/07-review-session.md §7.5.
public struct SubmissionStaging {
    public static let folderName = ".submission"

    /// The bundle to file.
    public var bundle: ReviewBundle
    /// The folder holding each media file (and where `review.json` is written).
    public var mediaDirectory: URL
    /// Annotations left out because they lie entirely outside their crop or trim.
    public var dropped: [String]
    /// The part of the draft staged (everything, unless adding part of it to an existing ticket).
    public var selection = ReviewSelection()
    /// Captures scaled down for AI: media id → their size before scaling (after any crop).
    public var scaledFrom: [String: PixelSize] = [:]
    private var folder: URL?

    /// Prepares `draft` (only the part `selection` includes) for filing, scaled to `scale` when
    /// given. Throws when a cropped or scaled image or a trimmed or scaled movie can't be made.
    public static func prepare(
        _ whole: ReviewDraft, selection: ReviewSelection = ReviewSelection(), scale: MediaScaleTarget? = nil
    ) throws -> SubmissionStaging {
        var draft = whole
        draft.bundle = selection.apply(to: whole.bundle)
        let (crops, trims) = DraftEdits.load(from: draft.directory).byMediaId(in: draft.bundle)
        let projected = EditProjection.submission(draft.bundle, crops: crops, trims: trims)
        let (filed, scaledFrom) = scale?.apply(to: projected.bundle) ?? (projected.bundle, [:])
        guard !crops.isEmpty || !trims.isEmpty || !scaledFrom.isEmpty || !selection.isEverything else {
            return SubmissionStaging(bundle: draft.bundle, mediaDirectory: draft.directory, dropped: [], selection: selection, folder: nil)
        }
        let sizes = Dictionary(filed.media.map { ($0.id, PixelSize(width: $0.pixelWidth, height: $0.pixelHeight)) }) { first, _ in first }
        let fileManager = FileManager.default
        let folder = draft.directory.appendingPathComponent(folderName, isDirectory: true)
        try? fileManager.removeItem(at: folder)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for item in draft.bundle.media {
                let source = draft.mediaURL(item)
                let target = folder.appendingPathComponent(item.filename)
                let scaledSize = scaledFrom[item.id] != nil ? sizes[item.id] : nil
                if item.kind == .image, crops[item.id] != nil || scaledSize != nil {
                    var image = try ImageFiles.loadImage(at: source)
                    if let crop = crops[item.id] {
                        guard let cropped = ImageCrop.apply(crop, to: image) else { throw ImageFileError.cannotWrite(target) }
                        image = cropped
                    }
                    if let scaledSize {
                        guard let scaled = ImageFiles.scaled(image, to: scaledSize) else { throw ImageFileError.cannotWrite(target) }
                        image = scaled
                    }
                    try ImageFiles.writePNG(image, to: target)
                } else if item.kind == .video, trims[item.id] != nil || scaledSize != nil {
                    try VideoTrim.export(source, range: trims[item.id], size: scaledSize, to: target)
                } else {
                    try fileManager.copyItem(at: source, to: target)
                }
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return SubmissionStaging(
            bundle: filed, mediaDirectory: folder, dropped: projected.dropped, selection: selection, scaledFrom: scaledFrom, folder: folder
        )
    }

    /// Removes the staging folder, if one was made.
    public func cleanUp() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }
}
