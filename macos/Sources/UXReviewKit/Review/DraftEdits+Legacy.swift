import Foundation

// Drafts edited before `HS2-71SSJG` had their capture files cropped or trimmed in place, with
// the untouched originals under `originals/` and `originals/crops.json` (`OriginalsIndex`)
// recording the crop or trim, and annotations in the cropped file's coordinates. Opening or
// submitting such a draft converts it once: the original goes back in place, annotations map
// back exactly, and the crop or trim moves to `edits.json`. Spec: docs/06 §6.6.
public extension ReviewDraftStore {
    /// Converts a draft from `originals/` to `edits.json`. Only trusted records are converted (the
    /// rules of `OriginalsIndex.prior` / `priorTrim`); other kept originals are left where they
    /// are and their files keep their current content. Safe to run again after an interruption:
    /// edits are written first, files copied back next, review.json last, and only then are the
    /// converted originals and the index removed.
    func migrateLegacyEdits(_ directory: URL) throws {
        let fileManager = FileManager.default
        let originals = directory.appendingPathComponent(EditorSession.originalsDirectory, isDirectory: true)
        guard fileManager.fileExists(atPath: originals.path) else { return }
        lock.lock()
        defer { lock.unlock() }
        var draft = try read(directory)
        let index = OriginalsIndex.load(from: originals)
        var edits = DraftEdits.load(from: directory)
        var restored: [(original: URL, file: URL)] = []
        for (position, item) in draft.bundle.media.enumerated() {
            let original = originals.appendingPathComponent(item.filename)
            guard fileManager.fileExists(atPath: original.path) else { continue }
            if item.kind == .image,
               let size = try? ImageFiles.pixelSize(of: original),
               let prior = index.prior(
                   filename: item.filename,
                   originalSize: PixelRect(x: 0, y: 0, width: size.width, height: size.height),
                   currentWidth: item.pixelWidth,
                   currentHeight: item.pixelHeight
               ) {
                for annotationIndex in draft.bundle.annotations.indices where draft.bundle.annotations[annotationIndex].mediaId == item.id {
                    let shape = draft.bundle.annotations[annotationIndex].shape
                    draft.bundle.annotations[annotationIndex].shape = EditProjection.shape(shape, outOf: prior.crop, to: prior.originalSize)
                }
                draft.bundle.media[position].pixelWidth = prior.originalSize.width
                draft.bundle.media[position].pixelHeight = prior.originalSize.height
                if prior.crop != prior.originalSize { edits.crops[item.filename] = prior.crop }
                restored.append((original, draft.mediaURL(item)))
            } else if item.kind == .video,
                      let prior = index.priorTrim(filename: item.filename, originalExists: true, currentDurationMs: item.durationMs) {
                for annotationIndex in draft.bundle.annotations.indices where draft.bundle.annotations[annotationIndex].mediaId == item.id {
                    if let range = draft.bundle.annotations[annotationIndex].timeRange {
                        draft.bundle.annotations[annotationIndex].timeRange = EditProjection.range(range, outOf: prior.trim)
                    }
                }
                draft.bundle.media[position].durationMs = prior.originalDurationMs
                edits.trims[item.filename] = prior.trim
                restored.append((original, draft.mediaURL(item)))
            }
        }
        try edits.save(to: directory)
        for (original, file) in restored {
            let copy = file.deletingLastPathComponent().appendingPathComponent(".migrating-\(file.lastPathComponent)")
            try? fileManager.removeItem(at: copy)
            try fileManager.copyItem(at: original, to: copy)
            _ = try fileManager.replaceItemAt(file, withItemAt: copy)
        }
        try write(draft.bundle, to: draft.bundleURL)
        for (original, _) in restored {
            try? fileManager.removeItem(at: original)
        }
        try? fileManager.removeItem(at: OriginalsIndex.url(in: originals))
        if (try? fileManager.contentsOfDirectory(atPath: originals.path))?.isEmpty ?? false {
            try? fileManager.removeItem(at: originals)
        }
    }
}
