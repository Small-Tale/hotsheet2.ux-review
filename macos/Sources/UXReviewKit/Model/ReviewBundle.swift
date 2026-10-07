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
    /// A path ending in an arrowhead at its last point, for example "move this here".
    case arrow(points: [NormPoint])
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
        case .arrow: .move
        case .insertion: .insert
        case .strike: .remove
        }
    }

    /// Axis-aligned bounds, used to project any shape onto Hot Sheet 2's rectangle-only
    /// annotations. Degenerate (zero-size) bounds grow to at least 1 unit so they stay valid.
    public var bounds: NormRect {
        let points: [NormPoint]
        switch self {
        case let .rect(rect), let .strike(rect):
            return rect
        case let .freehand(pts, _), let .arrow(pts):
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
    private enum CodingKeys: String, CodingKey { case type, rect, points, closed, point }

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
        case "arrow": self = try .arrow(points: container.decode([NormPoint].self, forKey: .points))
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
        case let .arrow(points): try container.encode(points, forKey: .points)
        case let .insertion(point): try container.encode(point, forKey: .point)
        }
    }
}

public enum MediaKind: String, Codable, Sendable {
    case image
    case video
}

/// One captured file in the bundle.
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

    public init(
        id: String,
        filename: String,
        kind: MediaKind,
        pixelWidth: Int,
        pixelHeight: Int,
        durationMs: Int? = nil,
        capturedAt: Date,
        context: CaptureContext? = nil
    ) {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationMs = durationMs
        self.capturedAt = capturedAt
        self.context = context
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
