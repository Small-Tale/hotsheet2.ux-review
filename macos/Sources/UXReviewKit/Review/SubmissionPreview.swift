import Foundation

/// What the Submit Review window shows for each capture: the capture as it will be filed, with
/// its crop or trim applied and the annotations outside them left out. Computed from the draft's
/// `edits.json` (`EditProjection.submission`) without touching any file. Spec:
/// docs/07-review-session.md §7.2.
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

    public init(_ bundle: ReviewBundle, edits: DraftEdits) {
        let (crops, trims) = edits.byMediaId(in: bundle)
        let (filed, dropped) = EditProjection.submission(bundle, crops: crops, trims: trims)
        let droppedIds = Set(dropped)
        var media: [String: Filed] = [:]
        for item in filed.media {
            let annotations = bundle.annotations.filter { $0.mediaId == item.id }
            let leftOut = annotations.count(where: { droppedIds.contains($0.id) })
            media[item.id] = Filed(
                pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight, durationMs: item.durationMs,
                crop: crops[item.id], trim: trims[item.id],
                annotationCount: annotations.count - leftOut, leftOutCount: leftOut
            )
        }
        self.media = media
        annotationCount = filed.annotations.count
        leftOutCount = dropped.count
    }
}
