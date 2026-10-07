import Foundation

/// Hot Sheet 2's rectangle-only `MediaAnnotation` (snake_case on the wire). Every UX Review
/// shape projects onto one of these by its bounds so Hot Sheet's gallery can show it.
public struct HotSheetMediaAnnotation: Codable, Equatable, Sendable {
    public var id: String
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var startMs: Int?
    public var endMs: Int?
    public var text: String

    enum CodingKeys: String, CodingKey {
        case id, x, y, width, height, text
        case startMs = "start_ms"
        case endMs = "end_ms"
    }
}

/// Everything needed to file one review in Hot Sheet: the intake ticket, the files to attach
/// (media plus the canonical `review.json`), and the per-media Hot Sheet annotation projection.
public struct ComposedReview: Equatable, Sendable {
    public var ticket: NewTicket
    public var bundleFilename: String
    public var mediaFilenames: [String]
    public var hotSheetAnnotations: [String: [HotSheetMediaAnnotation]]
}

/// Turns a review bundle into a Hot Sheet intake ticket that instructs the AI absorbing it to
/// split the review into individual tickets that reuse the same captured media.
/// The ticket body format is specified in docs/03-hotsheet-integration.md.
public enum TicketComposer {
    public static let bundleFilename = "review.json"
    public static let tag = "ux-review"

    public static func compose(_ bundle: ReviewBundle) -> ComposedReview {
        let numbered = Array(bundle.annotations.enumerated())
        var projection: [String: [HotSheetMediaAnnotation]] = [:]
        for (index, annotation) in numbered {
            let bounds = annotation.shape.bounds
            projection[annotation.mediaId, default: []].append(HotSheetMediaAnnotation(
                id: annotation.id,
                x: bounds.x,
                y: bounds.y,
                width: bounds.width,
                height: bounds.height,
                startMs: annotation.timeRange?.startMs,
                endMs: annotation.timeRange?.endMs,
                text: "#\(index + 1) [\(intentLabel(annotation))] \(annotation.note)"
            ))
        }
        let ticket = NewTicket(
            title: "UX review: \(bundle.title)",
            details: details(for: bundle),
            category: "task",
            tags: [tag],
            upNext: false
        )
        return ComposedReview(
            ticket: ticket,
            bundleFilename: bundleFilename,
            mediaFilenames: bundle.media.map(\.filename),
            hotSheetAnnotations: projection
        )
    }

    static func intentLabel(_ annotation: Annotation) -> String {
        annotation.effectiveIntents.map(\.rawValue).joined(separator: ", ")
    }

    static func details(for bundle: ReviewBundle) -> String {
        let filenames = bundle.media.map { "`attachment:\($0.filename)`" }.joined(separator: ", ")
        var lines: [String] = []
        lines.append("""
        ## Instructions for the AI processing this ticket

        This is a **UX review intake ticket** captured with UX Review. Do not implement it directly; \
        split it into individual tickets.

        1. Read every annotation below. `attachment:\(bundleFilename)` is the canonical, machine-readable \
        record (schema `\(bundle.schema)`, see the UX Review repo's `spec/review-bundle.schema.json`); \
        it holds exact shapes, intents, and time ranges.
        2. Create one ticket per distinct actionable change. Group annotations only when they describe \
        the same change; do not silently drop any annotation.
        3. In each new ticket, state the requested change and cite the annotation numbers, intents, \
        regions, and time ranges it covers. Reference the same captured media by name (\(filenames)) \
        and attach those same files to it; do not recapture.
        4. Choose the category from the intent: `bug` for bug, `feature` for insert and new behavior, \
        `issue` for comment, change, remove, and move, and `investigation` for question.
        5. Add a note here listing every ticket you created, then complete this ticket.
        """)

        if !bundle.summary.isEmpty {
            lines.append("## Reviewer summary\n\n\(bundle.summary)")
        }

        let context = contextLines(bundle)
        if !context.isEmpty {
            lines.append("## Capture context\n\n" + context.joined(separator: "\n"))
        }

        var mediaSection = ["## Media", ""]
        for item in bundle.media {
            var line = "- `attachment:\(item.filename)` (\(item.kind.rawValue), \(item.pixelWidth)×\(item.pixelHeight)"
            if let duration = item.durationMs { line += ", \(formatTime(duration))" }
            line += ")"
            mediaSection.append(line)
        }
        lines.append(mediaSection.joined(separator: "\n"))

        var annotationSection = ["## Annotations"]
        if bundle.annotations.isEmpty {
            annotationSection.append("\nNo annotations; see the reviewer summary and media.")
        }
        let filenameById = Dictionary(bundle.media.map { ($0.id, $0.filename) }, uniquingKeysWith: { first, _ in first })
        for (index, annotation) in bundle.annotations.enumerated() {
            let filename = filenameById[annotation.mediaId] ?? annotation.mediaId
            let bounds = annotation.shape.bounds
            var meta = "- Shape: \(annotation.shape.kind); region (0–10000): x \(bounds.x), y \(bounds.y), "
                + "w \(bounds.width), h \(bounds.height)"
            if let range = annotation.timeRange {
                meta += "\n- Time: \(formatTime(range.startMs))–\(formatTime(range.endMs))"
            }
            let note = annotation.note.isEmpty ? "_No note._" : annotation.note
            annotationSection.append("""

            ### #\(index + 1) · \(intentLabel(annotation)) · `attachment:\(filename)`

            \(meta)

            \(note)
            """)
        }
        lines.append(annotationSection.joined(separator: "\n"))
        return lines.joined(separator: "\n\n") + "\n"
    }

    static func contextLines(_ bundle: ReviewBundle) -> [String] {
        let context = bundle.context
        let pairs: [(String, String?)] = [
            ("App", context.appName.map { name in
                context.bundleIdentifier.map { "\(name) (`\($0)`)" } ?? name
            }),
            ("Window", context.windowTitle),
            ("URL", context.url),
            ("OS", context.osVersion),
        ]
        return pairs.compactMap { label, value in value.map { "- \(label): \($0)" } }
    }

    /// `m:ss.mmm`, for example `1:02.500`.
    static func formatTime(_ milliseconds: Int) -> String {
        let minutes = milliseconds / 60000
        let seconds = (milliseconds % 60000) / 1000
        let millis = milliseconds % 1000
        return String(format: "%d:%02d.%03d", minutes, seconds, millis)
    }
}
