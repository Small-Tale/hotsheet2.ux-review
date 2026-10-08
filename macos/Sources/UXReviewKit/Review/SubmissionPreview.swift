import Foundation

/// What the Submit Review window shows for each capture: the capture as it will be filed, with
/// its crop or trim applied, the annotations outside them left out, and its size scaled for AI.
/// Computed from the draft's `edits.json` (`EditProjection.submission`) without touching any
/// file. Spec: docs/07-review-session.md §7.2.
public struct SubmissionPreview: Equatable, Sendable {
    /// One capture as filed.
    public struct Filed: Equatable, Sendable {
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var durationMs: Int?
        /// The crop applied when filing (pixels of the draft file), if any.
        public var crop: PixelRect?
        /// The trim applied when filing (ms of the draft file), if any.
        public var trim: TimeRange?
        /// Annotations filed with this capture.
        public var annotationCount: Int
        /// Annotations entirely outside the crop or trim, left out when filing.
        public var leftOutCount: Int
        /// The size before scaling for AI (after any crop), when the capture is scaled down.
        public var scaledFrom: PixelSize?
        /// Who it is scaled for ("Claude", "Codex", "AI"), when it is scaled.
        public var scaledFor: String?

        /// "2576×1449 scaled for Claude", "800×500 cropped", or "1600×1000": the size as filed.
        public var sizeText: String {
            var text = "\(pixelWidth)×\(pixelHeight)"
            if crop != nil { text += " cropped" }
            if scaledFrom != nil { text += crop != nil ? ", scaled for \(scaledFor ?? "AI")" : " scaled for \(scaledFor ?? "AI")" }
            return text
        }

        /// "2 annotations outside the crop will be left out", or nil when none are.
        public var leftOutNote: String? {
            guard leftOutCount > 0 else { return nil }
            let what = crop != nil ? "the crop" : trim != nil ? "the trim" : "the capture"
            return "\(leftOutCount) annotation\(leftOutCount == 1 ? "" : "s") outside \(what) will be left out"
        }
    }

    /// By media id, for every capture in the bundle.
    public var media: [String: Filed]
    /// Annotations filed in all.
    public var annotationCount: Int
    /// Annotations left out in all.
    public var leftOutCount: Int

    /// - Parameter scale: the AI size captures are scaled down to when filing, if that is on
    ///   (`MediaScaleTarget`, the same rule `SubmissionStaging` applies).
    public init(_ bundle: ReviewBundle, edits: DraftEdits, scale: MediaScaleTarget? = nil) {
        let (crops, trims) = edits.byMediaId(in: bundle)
        let (projected, dropped) = EditProjection.submission(bundle, crops: crops, trims: trims)
        let (filed, scaledFrom) = scale?.apply(to: projected) ?? (projected, [:])
        let droppedIds = Set(dropped)
        var media: [String: Filed] = [:]
        for item in filed.media {
            let annotations = bundle.annotations.filter { $0.mediaId == item.id }
            let leftOut = annotations.count(where: { droppedIds.contains($0.id) })
            media[item.id] = Filed(
                pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight, durationMs: item.durationMs,
                crop: crops[item.id], trim: trims[item.id],
                annotationCount: annotations.count - leftOut, leftOutCount: leftOut,
                scaledFrom: scaledFrom[item.id], scaledFor: scaledFrom[item.id] == nil ? nil : scale?.audience
            )
        }
        self.media = media
        annotationCount = filed.annotations.count
        leftOutCount = dropped.count
    }
}
