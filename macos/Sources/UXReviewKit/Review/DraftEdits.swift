import CoreGraphics
import Foundation

/// `<draft>/edits.json`: each capture's crop and trim while the review is a draft. Capture files
/// are never rewritten while drafting; `review.json` keeps the untouched files' sizes and
/// durations, with annotations in their coordinates and times. The crop and trim are applied
/// only when the review is submitted (`EditProjection.submission`, `SubmissionStaging`).
/// Never attached to tickets. Spec: docs/06-annotation-editor.md §6.6, §6.10 (`HS2-71SSJG`).
public struct DraftEdits: Codable, Equatable, Sendable {
    public static let filename = "edits.json"
    public static let currentVersion = 1

    public var version = DraftEdits.currentVersion
    /// Image crops in pixels of the file, keyed by media filename.
    public var crops: [String: PixelRect] = [:]
    /// Movie trims in ms of the file, keyed by media filename.
    public var trims: [String: TimeRange] = [:]

    public init(crops: [String: PixelRect] = [:], trims: [String: TimeRange] = [:]) {
        self.crops = crops
        self.trims = trims
    }

    public var isEmpty: Bool { crops.isEmpty && trims.isEmpty }

    public static func url(in directory: URL) -> URL { directory.appendingPathComponent(filename) }

    /// The draft's edits, or none when the file is missing, unreadable, or another version (an
    /// unreadable record shows the captures uncropped; it never blocks editing or submitting).
    public static func load(from directory: URL) -> DraftEdits {
        guard let data = try? Data(contentsOf: url(in: directory)),
              let edits = try? JSONDecoder().decode(DraftEdits.self, from: data),
              edits.version == currentVersion
        else { return DraftEdits() }
        return edits
    }

    /// Writes the edits, or removes the file when there are none.
    public func save(to directory: URL) throws {
        let url = Self.url(in: directory)
        guard !isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The edits that fit `bundle`, keyed by media id: a crop inside its image (and smaller than
    /// it), a trim inside its movie (and shorter than it). Records for unknown files or that don't
    /// fit are ignored.
    public func byMediaId(in bundle: ReviewBundle) -> (crops: [String: PixelRect], trims: [String: TimeRange]) {
        var byCrop: [String: PixelRect] = [:]
        var byTrim: [String: TimeRange] = [:]
        for item in bundle.media {
            if item.kind == .image, let crop = crops[item.filename],
               crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
               crop.x + crop.width <= item.pixelWidth, crop.y + crop.height <= item.pixelHeight,
               crop != PixelRect(x: 0, y: 0, width: item.pixelWidth, height: item.pixelHeight) {
                byCrop[item.id] = crop
            }
            if item.kind == .video, let trim = trims[item.filename], let duration = item.durationMs,
               trim.startMs >= 0, trim.startMs < trim.endMs, trim.endMs <= duration,
               trim != TimeRange(startMs: 0, endMs: duration) {
                byTrim[item.id] = trim
            }
        }
        return (byCrop, byTrim)
    }
}

/// Moving annotations between a capture's own space and its crop or trim. The exact maps never
/// clip, so a shape outside the crop keeps coordinates beyond 0…10000 (or a range beyond the
/// clip) and comes back unchanged when the crop or trim is widened. `submission` clips, as a
/// crop or trim did before `HS2-71SSJG`. Spec: docs/06-annotation-editor.md §6.6, §6.10.
public enum EditProjection {
    private static let scale = Double(NormalizedSpace.max)

    // MARK: Exact maps

    /// `point` (normalized to an image of `size`) normalized to `crop` of it.
    public static func point(_ point: NormPoint, into crop: PixelRect, of size: PixelRect) -> NormPoint {
        NormPoint(
            x: Int(((Double(point.x) * Double(size.width) / scale - Double(crop.x)) * scale / Double(crop.width)).rounded()),
            y: Int(((Double(point.y) * Double(size.height) / scale - Double(crop.y)) * scale / Double(crop.height)).rounded())
        )
    }

    /// The inverse of `point(_:into:of:)`.
    public static func point(_ point: NormPoint, outOf crop: PixelRect, to size: PixelRect) -> NormPoint {
        NormPoint(
            x: Int(((Double(point.x) * Double(crop.width) / scale + Double(crop.x)) * scale / Double(size.width)).rounded()),
            y: Int(((Double(point.y) * Double(crop.height) / scale + Double(crop.y)) * scale / Double(size.height)).rounded())
        )
    }

    public static func shape(_ shape: Shape, into crop: PixelRect, of size: PixelRect) -> Shape {
        shape.mapPoints { point($0, into: crop, of: size) }
    }

    public static func shape(_ shape: Shape, outOf crop: PixelRect, to size: PixelRect) -> Shape {
        shape.mapPoints { point($0, outOf: crop, to: size) }
    }

    /// `range` (ms of a movie) in ms of `trim` of it.
    public static func range(_ range: TimeRange, into trim: TimeRange) -> TimeRange {
        TimeRange(startMs: range.startMs - trim.startMs, endMs: range.endMs - trim.startMs)
    }

    public static func range(_ range: TimeRange, outOf trim: TimeRange) -> TimeRange {
        TimeRange(startMs: range.startMs + trim.startMs, endMs: range.endMs + trim.startMs)
    }

    // MARK: Outside the crop or trim

    /// Whether `shape` lies entirely outside its media (its points may lie beyond 0…10000 after a
    /// crop). Touching the edge counts as inside, as it does for a crop.
    public static func isOutside(_ shape: Shape) -> Bool {
        let points: [NormPoint] = switch shape {
        case let .rect(rect), let .strike(rect):
            [NormPoint(x: rect.x, y: rect.y), NormPoint(x: rect.x + rect.width, y: rect.y + rect.height)]
        case let .freehand(pts, _), let .arrow(pts):
            pts
        case let .insertion(point):
            [point]
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return true }
        let limit = NormalizedSpace.max
        let boxed = if case .rect = shape { true } else if case .strike = shape { true } else { false }
        // A box needs real overlap (a crop drops boxes that only touch it); points may touch.
        return boxed
            ? maxX <= 0 || minX >= limit || maxY <= 0 || minY >= limit
            : maxX < 0 || minX > limit || maxY < 0 || minY > limit
    }

    /// Whether `range` (ms of a clip `durationMs` long) lies entirely outside the clip.
    public static func isOutside(_ range: TimeRange, durationMs: Int) -> Bool {
        range.endMs < 0 || range.startMs > durationMs
    }

    // MARK: Whole bundles

    /// The bundle as the editor edits it: cropped images at their crop's size, trimmed movies at
    /// the trim's length, and annotations mapped exactly (never clipped or dropped).
    public static func editing(_ bundle: ReviewBundle, crops: [String: PixelRect], trims: [String: TimeRange]) -> ReviewBundle {
        var edited = bundle
        for (index, item) in bundle.media.enumerated() {
            if let crop = crops[item.id] {
                edited.media[index].pixelWidth = crop.width
                edited.media[index].pixelHeight = crop.height
            }
            if let trim = trims[item.id] { edited.media[index].durationMs = trim.endMs - trim.startMs }
        }
        let byId = Dictionary(bundle.media.map { ($0.id, $0) }) { first, _ in first }
        for index in edited.annotations.indices {
            let annotation = edited.annotations[index]
            guard let item = byId[annotation.mediaId] else { continue }
            if let crop = crops[item.id] {
                edited.annotations[index].shape = shape(annotation.shape, into: crop, of: size(of: item))
            }
            if let trim = trims[item.id], let timeRange = annotation.timeRange {
                edited.annotations[index].timeRange = range(timeRange, into: trim)
            }
        }
        return edited
    }

    /// The bundle as submitted: `editing`, then `clippedToMedia`. Returns the ids left out.
    public static func submission(
        _ bundle: ReviewBundle,
        crops: [String: PixelRect],
        trims: [String: TimeRange]
    ) -> (bundle: ReviewBundle, dropped: [String]) {
        clippedToMedia(editing(bundle, crops: crops, trims: trims))
    }

    /// Clips each annotation to its media, as a crop or trim did before `HS2-71SSJG`: boxes are
    /// clipped, points pulled to the edge, ranges clamped into the clip; annotations entirely
    /// outside are left out. The result is a valid bundle. Returns the ids left out.
    public static func clippedToMedia(_ bundle: ReviewBundle) -> (bundle: ReviewBundle, dropped: [String]) {
        let byId = Dictionary(bundle.media.map { ($0.id, $0) }) { first, _ in first }
        var clipped = bundle
        var dropped: [String] = []
        clipped.annotations = bundle.annotations.compactMap { annotation in
            guard let item = byId[annotation.mediaId] else { return annotation }
            var kept = annotation
            let outsideTime = annotation.timeRange.map { range in
                item.durationMs.map { isOutside(range, durationMs: $0) } ?? false
            } ?? false
            let frame = MediaFrame(item)
            guard !isOutside(annotation.shape), !outsideTime,
                  let shape = ImageCrop.transform(annotation.shape, from: frame, crop: size(of: item))
            else {
                dropped.append(annotation.id)
                return nil
            }
            kept.shape = shape
            if let range = annotation.timeRange, let duration = item.durationMs {
                kept.timeRange = TimeRange(startMs: min(max(range.startMs, 0), duration), endMs: min(max(range.endMs, 0), duration))
            }
            return kept
        }
        return (clipped, dropped)
    }

    static func size(of item: MediaItem) -> PixelRect {
        PixelRect(x: 0, y: 0, width: item.pixelWidth, height: item.pixelHeight)
    }
}
