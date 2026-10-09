import Foundation

// The review bundle is UX Review's platform-neutral interchange format. It is the canonical
// record of one review session and is attached to the Hot Sheet ticket as `review.json`.
// Source of truth: spec/review-bundle.schema.json and docs/02-review-bundle.md. Keep this
// file, the schema, and the docs in sync.

/// Coordinates are normalized integers in `0...NormalizedSpace.max`, relative to the media
/// itself (not the screen), matching Hot Sheet 2's `MediaAnnotation` coordinate space.
public enum NormalizedSpace {
    public static let max = 10000
}

public struct NormPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    var isInBounds: Bool {
        (0 ... NormalizedSpace.max).contains(x) && (0 ... NormalizedSpace.max).contains(y)
    }
}

public struct NormRect: Codable, Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Positive size and fully inside the media, per Hot Sheet 2's annotation validation.
    var isValid: Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= NormalizedSpace.max && y + height <= NormalizedSpace.max
    }
}

/// An inclusive time range in milliseconds. Equal endpoints mark a single instant.
public struct TimeRange: Codable, Equatable, Hashable, Sendable {
    public var startMs: Int
    public var endMs: Int

    public init(startMs: Int, endMs: Int) {
        self.startMs = startMs
        self.endMs = endMs
    }

    var isValid: Bool { startMs >= 0 && startMs <= endMs }

    /// True when `millis` lies inside the range (both ends inclusive).
    public func contains(_ millis: Int) -> Bool { startMs <= millis && millis <= endMs }
}

/// What the reviewer wants done about the marked area. Intents are modifiers that can be
/// combined with any shape; marker shapes imply a default intent (see `Shape.defaultIntent`).
public enum Intent: String, Codable, CaseIterable, Sendable {
    /// General observation or feedback.
    case comment
    /// Something is broken or wrong.
    case bug
    /// Change the marked element (style, copy, behavior).
    case change
    /// Insert something at the marked place.
    case insert
    /// Remove the marked element.
    case remove
    /// Move the marked element (usually along an arrow).
    case move
    /// Open question for the product owner or developer.
    case question
}

/// The geometry of an annotation.
public enum Shape: Equatable, Hashable, Sendable {
    /// Rectangular region.
    case rect(NormRect)
    /// Hand-drawn outline of a non-rectangular region; `closed` joins the last point to the first.
    case freehand(points: [NormPoint], closed: Bool)
    /// A path from its first point to its last, with a head at each end (`ArrowHeads`). The
    /// standard arrow has a head at the last point only, for example "move this here"; other
    /// heads mark a span, a relation, or a line (`HS2-HQV9R8`).
    case arrow(points: [NormPoint], heads: ArrowHeads = .standard)
    /// Caret marking an insertion point.
    case insertion(NormPoint)
    /// Strike / X marker over something that should be removed.
    case strike(NormRect)

    public var kind: String {
        switch self {
        case .rect: "rect"
        case .freehand: "freehand"
        case .arrow: "arrow"
        case .insertion: "insertion"
        case .strike: "strike"
        }
    }

    public var defaultIntent: Intent {
        switch self {
        case .rect, .freehand: .comment
        case let .arrow(_, heads): heads.pointsOneWay ? .move : .comment
        case .insertion: .insert
        case .strike: .remove
        }
    }

    /// An arrow's heads when they differ from the standard arrow ("start flat, end flat"), else nil.
    public var arrowHeadsSummary: String? {
        if case let .arrow(_, heads) = self { heads.summary } else { nil }
    }

    /// Axis-aligned bounds, used to project any shape onto Hot Sheet 2's rectangle-only
    /// annotations. Degenerate (zero-size) bounds grow to at least 1 unit so they stay valid.
    public var bounds: NormRect {
        let points: [NormPoint]
        switch self {
        case let .rect(rect), let .strike(rect):
            return rect
        case let .freehand(pts, _), let .arrow(pts, _):
            points = pts
        case let .insertion(point):
            points = [point]
        }
        guard let first = points.first else { return NormRect(x: 0, y: 0, width: 1, height: 1) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let limit = NormalizedSpace.max
        let x = min(max(minX, 0), limit - 1)
        let y = min(max(minY, 0), limit - 1)
        let width = max(min(maxX, limit) - x, 1)
        let height = max(min(maxY, limit) - y, 1)
        return NormRect(x: x, y: y, width: width, height: height)
    }
}

extension Shape: Codable {
    private enum CodingKeys: String, CodingKey { case type, rect, points, closed, point, startHead, endHead }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "rect": self = try .rect(container.decode(NormRect.self, forKey: .rect))
        case "strike": self = try .strike(container.decode(NormRect.self, forKey: .rect))
        case "freehand":
            self = try .freehand(
                points: container.decode([NormPoint].self, forKey: .points),
                closed: container.decodeIfPresent(Bool.self, forKey: .closed) ?? true
            )
        case "arrow":
            self = try .arrow(points: container.decode([NormPoint].self, forKey: .points), heads: ArrowHeads(
                start: container.decodeIfPresent(ArrowHead.self, forKey: .startHead) ?? ArrowHeads.standard.start,
                end: container.decodeIfPresent(ArrowHead.self, forKey: .endHead) ?? ArrowHeads.standard.end
            ))
        case "insertion": self = try .insertion(container.decode(NormPoint.self, forKey: .point))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown shape type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case let .rect(rect), let .strike(rect): try container.encode(rect, forKey: .rect)
        case let .freehand(points, closed):
            try container.encode(points, forKey: .points)
            try container.encode(closed, forKey: .closed)
        case let .arrow(points, heads):
            try container.encode(points, forKey: .points)
            // Only heads that differ from the standard arrow are written.
            if heads.start != ArrowHeads.standard.start { try container.encode(heads.start, forKey: .startHead) }
            if heads.end != ArrowHeads.standard.end { try container.encode(heads.end, forKey: .endHead) }
        case let .insertion(point): try container.encode(point, forKey: .point)
        }
    }
}

/// What an arrow ends with (`HS2-HQV9R8`). Spec: docs/02-review-bundle.md.
public enum ArrowHead: String, Codable, CaseIterable, Sendable {
    /// No head: the line just ends.
    case none
    /// An open arrowhead: two strokes in a V.
    case open
    /// A filled triangle; the standard arrow's head.
    case closed
    /// A bar across the line, as on a span or dimension line.
    case flat
    /// A hollow circle.
    case openCircle
    /// A filled circle.
    case closedCircle

    /// The style's name in the editor, for VoiceOver, and in ticket text.
    public var displayName: String {
        switch self {
        case .none: "None"
        case .open: "Open"
        case .closed: "Closed"
        case .flat: "Flat"
        case .openCircle: "Open circle"
        case .closedCircle: "Closed circle"
        }
    }

    /// An arrowhead proper (open or closed), as opposed to a bar, a circle, or nothing.
    public var pointsTheWay: Bool { self == .open || self == .closed }
}

/// The heads at an arrow's start (first point) and end (last point).
public struct ArrowHeads: Hashable, Sendable {
    public var start: ArrowHead
    public var end: ArrowHead

    public init(start: ArrowHead, end: ArrowHead) {
        self.start = start
        self.end = end
    }

    /// Today's arrow: nothing at the start, a filled head at the end.
    public static let standard = ArrowHeads(start: .none, end: .closed)

    /// An arrowhead at exactly one end and nothing at the other: the arrow shows a direction,
    /// so its default intent is move. Anything else (both ends, bars, circles, no heads) marks a
    /// span or a relation and defaults to comment.
    public var pointsOneWay: Bool {
        (end.pointsTheWay && start == .none) || (start.pointsTheWay && end == .none)
    }

    /// "start flat, end closed circle" for the ticket text and VoiceOver; nil for the standard arrow.
    public var summary: String? {
        guard self != .standard else { return nil }
        return "start \(start.displayName.lowercased()), end \(end.displayName.lowercased())"
    }
}

public enum MediaKind: String, Codable, Sendable {
    case image
    case video
}

/// One captured file in the bundle.
/// A media size in pixels, as `review.json` writes it (`pixelWidth`, `pixelHeight`).
public struct MediaPixelSize: Codable, Equatable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(pixelWidth: Int, pixelHeight: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct MediaItem: Codable, Equatable, Sendable {
    public var id: String
    /// File name as attached to the ticket; tickets reference it as `attachment:<filename>`.
    public var filename: String
    public var kind: MediaKind
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Video duration after trimming; nil for images.
    public var durationMs: Int?
    public var capturedAt: Date
    /// Where this capture came from. A review can mix captures of several apps; the bundle-level
    /// `context` describes the review as a whole (by default, its first capture).
    public var context: CaptureContext?
    /// Video only: `true` when the movie has an audio track, such as microphone narration
    /// (docs/04-capture.md §4.9) or an imported movie's sound. Nil means no audio or unknown
    /// (bundles written before the field existed); writers never store `false`, so it is
    /// omitted from `review.json`. Spec: docs/02-review-bundle.md §2.2.
    public var hasAudio: Bool?
    /// The capture's size before it was downscaled for AI (after any crop), only when it was
    /// (docs/07 §7.5.1). Tells a reader the attachment lost detail. Spec: docs/02 §2.2.
    public var scaledFrom: MediaPixelSize?
    /// The reviewer's Markdown note about the capture as a whole (`HS2-KVDDFH`). Nil when there is
    /// none; never empty, so it is omitted from `review.json`. Spec: docs/02 §2.2.
    public var note: String?

    public init(
        id: String,
        filename: String,
        kind: MediaKind,
        pixelWidth: Int,
        pixelHeight: Int,
        durationMs: Int? = nil,
        capturedAt: Date,
        context: CaptureContext? = nil,
        hasAudio: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationMs = durationMs
        self.capturedAt = capturedAt
        self.context = context
        self.hasAudio = hasAudio ? true : nil
    }
}

public struct Annotation: Codable, Equatable, Sendable {
    public var id: String
    public var mediaId: String
    public var shape: Shape
    /// Empty means "use the shape's default intent".
    public var intents: [Intent]
    /// Markdown note from the reviewer.
    public var note: String
    /// Video only: when the annotation applies. Nil means the whole clip.
    public var timeRange: TimeRange?

    public init(id: String, mediaId: String, shape: Shape, intents: [Intent] = [], note: String, timeRange: TimeRange? = nil) {
        self.id = id
        self.mediaId = mediaId
        self.shape = shape
        self.intents = intents
        self.note = note
        self.timeRange = timeRange
    }

    public var effectiveIntents: [Intent] { intents.isEmpty ? [shape.defaultIntent] : intents }

    /// True when the annotation shows at `millis` into its clip: it has no range (the whole clip), or
    /// the range contains `millis`.
    public func isVisible(atMs millis: Int) -> Bool { timeRange?.contains(millis) ?? true }
}

/// Where the capture came from, to help whoever acts on the ticket reproduce it.
public struct CaptureContext: Codable, Equatable, Sendable {
    /// True when no field is set.
    public var isEmpty: Bool {
        appName == nil && bundleIdentifier == nil && windowTitle == nil && url == nil && osVersion == nil && displayScale == nil
    }

    public var appName: String?
    public var bundleIdentifier: String?
    public var windowTitle: String?
    public var url: String?
    public var osVersion: String?
    public var displayScale: Double?

    public init(
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        osVersion: String? = nil,
        displayScale: Double? = nil
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.url = url
        self.osVersion = osVersion
        self.displayScale = displayScale
    }
}

public struct ReviewBundle: Codable, Equatable, Sendable {
    public static let currentSchema = "uxreview/bundle/v1"

    public var schema: String
    public var id: String
    public var title: String
    /// Overall Markdown notes for the review session.
    public var summary: String
    public var createdAt: Date
    public var context: CaptureContext
    public var media: [MediaItem]
    public var annotations: [Annotation]

    public init(
        id: String,
        title: String,
        summary: String = "",
        createdAt: Date,
        context: CaptureContext = CaptureContext(),
        media: [MediaItem],
        annotations: [Annotation]
    ) {
        schema = Self.currentSchema
        self.id = id
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
        self.context = context
        self.media = media
        self.annotations = annotations
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
