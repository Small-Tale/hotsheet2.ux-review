import Foundation

/// What gets filed for a draft: its crops and trims applied (`HS2-71SSJG`). With nothing cropped
/// or trimmed this is the draft itself. Otherwise a hidden `.submission` folder in the draft
/// holds a cropped PNG for each cropped image, a trimmed movie for each trimmed one, and copies
/// of the rest, and the bundle has annotations clipped to them and those entirely outside left
/// out (`EditProjection.submission`). Spec: docs/07-review-session.md §7.5.
public struct SubmissionStaging {
    public static let folderName = ".submission"

    /// The bundle to file.
    public var bundle: ReviewBundle
    /// The folder holding each media file (and where `review.json` is written).
    public var mediaDirectory: URL
    /// Annotations left out because they lie entirely outside their crop or trim.
    public var dropped: [String]
    private var folder: URL?

    /// Prepares `draft` for filing. Throws when a cropped image or trimmed movie can't be made.
    public static func prepare(_ draft: ReviewDraft) throws -> SubmissionStaging {
        let (crops, trims) = DraftEdits.load(from: draft.directory).byMediaId(in: draft.bundle)
        guard !crops.isEmpty || !trims.isEmpty else {
            return SubmissionStaging(bundle: draft.bundle, mediaDirectory: draft.directory, dropped: [], folder: nil)
        }
        let fileManager = FileManager.default
        let folder = draft.directory.appendingPathComponent(folderName, isDirectory: true)
        try? fileManager.removeItem(at: folder)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for item in draft.bundle.media {
                let source = draft.mediaURL(item)
                let target = folder.appendingPathComponent(item.filename)
                if let crop = crops[item.id] {
                    let image = try ImageFiles.loadImage(at: source)
                    guard let cropped = ImageCrop.apply(crop, to: image) else { throw ImageFileError.cannotWrite(target) }
                    try ImageFiles.writePNG(cropped, to: target)
                } else if let trim = trims[item.id] {
                    try VideoTrim.export(source, range: trim, to: target)
                } else {
                    try fileManager.copyItem(at: source, to: target)
                }
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        let projected = EditProjection.submission(draft.bundle, crops: crops, trims: trims)
        return SubmissionStaging(bundle: projected.bundle, mediaDirectory: folder, dropped: projected.dropped, folder: folder)
    }

    /// Removes the staging folder, if one was made.
    public func cleanUp() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }
}
