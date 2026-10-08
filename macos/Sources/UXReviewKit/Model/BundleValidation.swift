import Foundation

/// A rule the bundle breaks. Rules mirror Hot Sheet 2's annotation validation where they overlap.
public enum BundleIssue: Equatable, Sendable {
    case unsupportedSchema(String)
    case noMedia
    case duplicateMediaId(String)
    case duplicateFilename(String)
    case invalidMediaSize(mediaId: String)
    case duplicateAnnotationId(String)
    case unknownMedia(annotationId: String, mediaId: String)
    case shapeOutOfBounds(annotationId: String)
    case tooFewPoints(annotationId: String, minimum: Int)
    case invalidTimeRange(annotationId: String)
    case timeRangeOnImage(annotationId: String)
    case timeRangeBeyondDuration(annotationId: String)
}

public extension ReviewBundle {
    /// Every rule violation, in a stable order. An empty array means the bundle is valid.
    func validate() -> [BundleIssue] {
        var issues: [BundleIssue] = []
        if schema != Self.currentSchema { issues.append(.unsupportedSchema(schema)) }
        if media.isEmpty { issues.append(.noMedia) }

        var mediaById: [String: MediaItem] = [:]
        var filenames: Set<String> = []
        for item in media {
            if mediaById[item.id] != nil { issues.append(.duplicateMediaId(item.id)) }
            mediaById[item.id] = item
            if !filenames.insert(item.filename).inserted { issues.append(.duplicateFilename(item.filename)) }
            let badScaledFrom = item.scaledFrom.map { $0.pixelWidth <= 0 || $0.pixelHeight <= 0 } ?? false
            if item.pixelWidth <= 0 || item.pixelHeight <= 0 || badScaledFrom { issues.append(.invalidMediaSize(mediaId: item.id)) }
        }

        var annotationIds: Set<String> = []
        for annotation in annotations {
            let id = annotation.id
            if !annotationIds.insert(id).inserted { issues.append(.duplicateAnnotationId(id)) }
            let item = mediaById[annotation.mediaId]
            if item == nil { issues.append(.unknownMedia(annotationId: id, mediaId: annotation.mediaId)) }
            issues += Self.shapeIssues(annotation.shape, annotationId: id)
            if let range = annotation.timeRange {
                if !range.isValid { issues.append(.invalidTimeRange(annotationId: id)) }
                if item?.kind == .image { issues.append(.timeRangeOnImage(annotationId: id)) }
                if let duration = item?.durationMs, range.endMs > duration {
                    issues.append(.timeRangeBeyondDuration(annotationId: id))
                }
            }
        }
        return issues
    }

    private static func shapeIssues(_ shape: Shape, annotationId id: String) -> [BundleIssue] {
        switch shape {
        case let .rect(rect), let .strike(rect):
            rect.isValid ? [] : [.shapeOutOfBounds(annotationId: id)]
        case let .insertion(point):
            point.isInBounds ? [] : [.shapeOutOfBounds(annotationId: id)]
        case let .arrow(points, _):
            pointIssues(points, minimum: 2, annotationId: id)
        case let .freehand(points, _):
            pointIssues(points, minimum: 3, annotationId: id)
        }
    }

    private static func pointIssues(_ points: [NormPoint], minimum: Int, annotationId id: String) -> [BundleIssue] {
        var issues: [BundleIssue] = []
        if points.count < minimum { issues.append(.tooFewPoints(annotationId: id, minimum: minimum)) }
        if !points.allSatisfy(\.isInBounds) { issues.append(.shapeOutOfBounds(annotationId: id)) }
        return issues
    }
}
