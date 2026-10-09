import Foundation

/// Hot Sheet 2's `MediaAnnotation` (snake_case on the wire). `x/y/width/height` is always the
/// shape's bounding box, so a reader that ignores `shape` still places it. Spec: docs/03 §3.4.
public struct HotSheetMediaAnnotation: Codable, Equatable, Sendable {
    public var id: String
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var startMs: Int?
    public var endMs: Int?
    public var text: String
    /// Nil is a rectangle. Any shape raises the ticket's format marker to `v3-annotation-shapes`.
    public var shape: HotSheetShape?
    /// Intent names, in order; nil means the shape's default in Hot Sheet. Any intents raise the
    /// ticket's format marker to `v4-annotation-intents`.
    public var intents: [String]?

    public init(
        id: String, x: Int, y: Int, width: Int, height: Int, startMs: Int?, endMs: Int?, text: String,
        shape: HotSheetShape? = nil, intents: [String]? = nil
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.shape = shape
        self.intents = intents
    }

    enum CodingKeys: String, CodingKey {
        case id, x, y, width, height, text, shape, intents
        case startMs = "start_ms"
        case endMs = "end_ms"
    }

    // Hot Sheet omits an empty `text` and `intents`; decode them as "" and nil.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        x = try container.decode(Int.self, forKey: .x)
        y = try container.decode(Int.self, forKey: .y)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        startMs = try container.decodeIfPresent(Int.self, forKey: .startMs)
        endMs = try container.decodeIfPresent(Int.self, forKey: .endMs)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        shape = try container.decodeIfPresent(HotSheetShape.self, forKey: .shape)
        intents = try container.decodeIfPresent([String].self, forKey: .intents).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// True when Hot Sheet stored everything this annotation asked for. A CLI that predates
    /// shapes or intents keeps the box and text but silently drops the rest.
    public func isKept(by stored: HotSheetMediaAnnotation) -> Bool {
        stored.id == id && (shape == nil || stored.shape == shape) && (intents == nil || stored.intents == intents)
    }
}

/// Hot Sheet 2's annotation shapes beyond the rectangle, tagged by `type`.
public enum HotSheetShape: Codable, Equatable, Sendable {
    case rect
    /// The bounding box, crossed out.
    case strike
    case freehand(points: [NormPoint], closed: Bool)
    /// A line through `points` with one filled head, at the last point.
    case arrow(points: [NormPoint])
    case insertion(NormPoint)

    private enum CodingKeys: String, CodingKey { case type, points, closed, point }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "rect": self = .rect
        case "strike": self = .strike
        case "freehand":
            self = try .freehand(
                points: container.decode([NormPoint].self, forKey: .points),
                closed: container.decodeIfPresent(Bool.self, forKey: .closed) ?? true
            )
        case "arrow": self = try .arrow(points: container.decode([NormPoint].self, forKey: .points))
        case "insertion": self = try .insertion(container.decode(NormPoint.self, forKey: .point))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown shape \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rect: try container.encode("rect", forKey: .type)
        case .strike: try container.encode("strike", forKey: .type)
        case let .freehand(points, closed):
            try container.encode("freehand", forKey: .type)
            try container.encode(points, forKey: .points)
            if !closed { try container.encode(false, forKey: .closed) }
        case let .arrow(points):
            try container.encode("arrow", forKey: .type)
            try container.encode(points, forKey: .points)
        case let .insertion(point):
            try container.encode("insertion", forKey: .type)
            try container.encode(point, forKey: .point)
        }
    }

    /// The intent Hot Sheet assumes when `intents` is empty.
    var defaultIntent: Intent {
        switch self {
        case .rect, .freehand: .comment
        case .strike: .remove
        case .arrow: .move
        case .insertion: .insert
        }
    }
}

/// Everything needed to file one review in Hot Sheet: the intake ticket, the files to attach
/// (media plus the canonical `review.json`), and the per-media Hot Sheet annotation projections.
public struct ComposedReview: Equatable, Sendable {
    public var ticket: NewTicket
    public var bundleFilename: String
    public var mediaFilenames: [String]
    /// Media id → native annotations: real shapes and intents (docs/03 §3.4).
    public var hotSheetAnnotations: [String: [HotSheetMediaAnnotation]]
    /// Media id → rectangle-only annotations with the intents in `text`, for a Hot Sheet that
    /// predates shapes and intents.
    public var legacyHotSheetAnnotations: [String: [HotSheetMediaAnnotation]]
}

/// Turns a review bundle into a Hot Sheet intake ticket that instructs the AI absorbing it to
/// split the review into individual tickets that reuse the same captured media.
/// The ticket body format is specified in docs/03-hotsheet-integration.md.
public enum TicketComposer {
    public static let bundleFilename = "review.json"
    public static let tag = "ux-review"

    /// - Parameter preamble: the reviewer's edited instructions template (docs/07 §7.2.3); nil
    ///   for the standard one.
    public static func compose(_ bundle: ReviewBundle, preamble: String? = nil) -> ComposedReview {
        var native: [String: [HotSheetMediaAnnotation]] = [:]
        var legacy: [String: [HotSheetMediaAnnotation]] = [:]
        for (index, annotation) in bundle.annotations.enumerated() {
            native[annotation.mediaId, default: []].append(hotSheetAnnotation(annotation, number: index + 1))
            legacy[annotation.mediaId, default: []].append(legacyHotSheetAnnotation(annotation, number: index + 1))
        }
        let ticket = NewTicket(
            // The review's title is the ticket's title, as typed (HS2-025XNF): one title, edited
            // under Review in the Submit Review window. The ux-review tag marks intake tickets.
            title: bundle.title.trimmingCharacters(in: .whitespacesAndNewlines),
            details: details(for: bundle, preamble: preamble),
            category: "task",
            tags: [tag],
            upNext: false
        )
        return ComposedReview(
            ticket: ticket,
            bundleFilename: bundleFilename,
            mediaFilenames: bundle.media.map(\.filename),
            hotSheetAnnotations: native,
            legacyHotSheetAnnotations: legacy
        )
    }

    /// One annotation as Hot Sheet's native shape and intents (docs/03 §3.4). `text` keeps the
    /// ticket body's `#N`, since Hot Sheet numbers its badges on its own.
    static func hotSheetAnnotation(_ annotation: Annotation, number: Int) -> HotSheetMediaAnnotation {
        let shape = hotSheetShape(annotation.shape)
        let intents = annotation.effectiveIntents
        let bounds = annotation.shape.bounds
        return HotSheetMediaAnnotation(
            id: annotation.id,
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height,
            startMs: annotation.timeRange?.startMs,
            endMs: annotation.timeRange?.endMs,
            text: annotation.note.isEmpty ? "#\(number)" : "#\(number) \(annotation.note)",
            shape: shape == .rect ? nil : shape,
            // Only when they differ from Hot Sheet's default, so a plain comment box stays a v2 ticket.
            intents: intents == [shape.defaultIntent] ? nil : intents.map(\.rawValue)
        )
    }

    /// UX Review's shape as Hot Sheet draws it. Hot Sheet's arrow has one head, at its last point:
    /// an arrow with a head at one end only maps onto it (reversed when the head is at the start);
    /// any other heads (a span, bars, circles, none) become an open line, with a midpoint added so
    /// a two-point line meets freehand's three-point minimum.
    static func hotSheetShape(_ shape: Shape) -> HotSheetShape {
        switch shape {
        case .rect: return .rect
        case .strike: return .strike
        case let .insertion(point): return .insertion(point)
        case let .freehand(points, closed): return .freehand(points: points, closed: closed)
        case let .arrow(points, heads):
            if heads.pointsOneWay {
                return .arrow(points: heads.end.pointsTheWay ? points : points.reversed())
            }
            guard points.count == 2 else { return .freehand(points: points, closed: false) }
            let mid = NormPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
            return .freehand(points: [points[0], mid, points[1]], closed: false)
        }
    }

    /// One annotation as a plain rectangle with `#N [intents] note`, for an older Hot Sheet.
    static func legacyHotSheetAnnotation(_ annotation: Annotation, number: Int) -> HotSheetMediaAnnotation {
        let bounds = annotation.shape.bounds
        return HotSheetMediaAnnotation(
            id: annotation.id,
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height,
            startMs: annotation.timeRange?.startMs,
            endMs: annotation.timeRange?.endMs,
            text: "#\(number) [\(intentLabel(annotation))] \(annotation.note)"
        )
    }

    /// The Markdown note that adds a review to an existing ticket instead of filing an intake
    /// ticket (docs/03 §3.5): the review's title, what was attached, then the same sections as an
    /// intake ticket body, one heading level deeper. No splitting instructions: the review is
    /// feedback on this ticket.
    /// - Parameters:
    ///   - storedNames: draft file name → the name Hot Sheet stored it under, for files
    ///     it renamed because the ticket already had one by that name.
    ///   - preamble: the reviewer's edited intro template (docs/07 §7.2.3); nil for the standard one.
    public static func note(for bundle: ReviewBundle, storedNames: [String: String] = [:], preamble: String? = nil) -> String {
        let intro = TicketPreamble.text(.existingTicket, for: bundle, template: preamble, storedNames: storedNames)
        let sections = reviewSections(bundle, heading: "###", storedNames: storedNames)
        return ((intro.isEmpty ? [] : [intro]) + sections).joined(separator: "\n\n") + "\n"
    }

    static func intentLabel(_ annotation: Annotation) -> String {
        annotation.effectiveIntents.map(\.rawValue).joined(separator: ", ")
    }

    static func details(for bundle: ReviewBundle, preamble: String? = nil) -> String {
        let instructions = TicketPreamble.text(.newTicket, for: bundle, template: preamble)
        let sections = reviewSections(bundle, heading: "##", storedNames: [:])
        return ((instructions.isEmpty ? [] : [instructions]) + sections).joined(separator: "\n\n") + "\n"
    }

    /// The part of a review that reads the same in an intake ticket and in a note on an existing
    /// ticket: reviewer summary, capture context, media, and one section per annotation.
    /// - Parameters:
    ///   - heading: the Markdown level of the section headings (`##`); annotations go one deeper.
    ///   - storedNames: draft file name → the name Hot Sheet stored it under, when it differs.
    static func reviewSections(_ bundle: ReviewBundle, heading: String, storedNames: [String: String]) -> [String] {
        var lines: [String] = []
        if !bundle.summary.isEmpty {
            lines.append("\(heading) Reviewer summary\n\n\(bundle.summary)")
        }

        let context = contextLines(bundle)
        if !context.isEmpty {
            lines.append("\(heading) Capture context\n\n" + context.joined(separator: "\n"))
        }

        lines.append(mediaSection(bundle, heading: heading, storedNames: storedNames))

        var annotationSection = ["\(heading) Annotations"]
        if bundle.annotations.isEmpty {
            annotationSection.append("\nNo annotations; see the reviewer summary and media.")
        }
        let filenameById = Dictionary(bundle.media.map { ($0.id, $0.filename) }, uniquingKeysWith: { first, _ in first })
        for (index, annotation) in bundle.annotations.enumerated() {
            let filename = filenameById[annotation.mediaId].map { storedNames[$0] ?? $0 } ?? annotation.mediaId
            let bounds = annotation.shape.bounds
            let heads = annotation.shape.arrowHeadsSummary.map { " (\($0))" } ?? ""
            var meta = "- Shape: \(annotation.shape.kind)\(heads); region (0–10000): x \(bounds.x), y \(bounds.y), "
                + "w \(bounds.width), h \(bounds.height)"
            if let range = annotation.timeRange {
                meta += "\n- Time: \(formatTime(range.startMs))–\(formatTime(range.endMs))"
            }
            let note = annotation.note.isEmpty ? "_No note._" : annotation.note
            annotationSection.append("""

            \(heading)# #\(index + 1) · \(intentLabel(annotation)) · \(attachmentReference(filename))

            \(meta)

            \(note)
            """)
        }
        lines.append(annotationSection.joined(separator: "\n"))
        return lines
    }

    /// `` `attachment:<name>` `` as a Markdown code span, fenced with enough backticks for a name
    /// that contains some.
    static func attachmentReference(_ filename: String) -> String {
        codeSpan("attachment:\(filename)")
    }

    static func codeSpan(_ text: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
        return fence + pad + text + pad + fence
    }

    static func mediaSection(_ bundle: ReviewBundle, heading: String = "##", storedNames: [String: String] = [:]) -> String {
        var lines = ["\(heading) Media", ""]
        for item in bundle.media {
            let stored = storedNames[item.filename] ?? item.filename
            var line = "- \(attachmentReference(stored)) (\(item.kind.rawValue), \(item.pixelWidth)×\(item.pixelHeight)"
            if let original = item.scaledFrom { line += ", scaled from \(original.pixelWidth)×\(original.pixelHeight)" }
            if let duration = item.durationMs { line += ", \(formatTime(duration))" }
            if item.hasAudio == true { line += ", with audio" }
            line += ")"
            if let source = sourceLabel(item.context) { line += ", from \(source)" }
            if stored != item.filename { line += "; stored under this name, `\(bundleFilename)` calls it \(codeSpan(item.filename))" }
            lines.append(line)
            if let note = item.note { lines.append(captureNote(note)) }
        }
        if bundle.media.contains(where: { $0.hasAudio == true }) {
            lines += ["", audioHint]
        }
        if bundle.media.contains(where: { $0.scaledFrom != nil }) {
            lines += ["", scaledHint]
        }
        return lines.joined(separator: "\n")
    }

    /// A capture's own note (`HS2-KVDDFH`) under its media line, every line indented two spaces so
    /// Markdown keeps it inside that list item; blank lines stay blank.
    static func captureNote(_ note: String) -> String {
        note.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            let text = index == 0 ? "Capture note: \(line)" : String(line)
            return text.isEmpty ? "" : "  \(text)"
        }.joined(separator: "\n")
    }

    /// Follows the media list when a video has sound, so the agent doesn't treat it as silent.
    static let audioHint = "Videos marked “with audio” have a sound track, usually the reviewer's spoken narration. "
        + "Listen to or transcribe it: it can explain the annotations or ask for changes they don't show."

    /// Follows the media list when a capture was downscaled for AI (HS2-KMB528).
    static let scaledHint = "Captures marked “scaled from” were downscaled for AI before filing, so they show less detail "
        + "than the reviewer saw. Annotation regions still line up: they are relative to the media. If you need finer "
        + "detail, ask the reviewer for a crop of that area."

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

    /// "Safari “Settings”", "Safari", or "“Settings”" for a capture's own context.
    static func sourceLabel(_ context: CaptureContext?) -> String? {
        switch (context?.appName, context?.windowTitle) {
        case let (app?, window?): "\(app) “\(window)”"
        case let (app?, nil): app
        case let (nil, window?): "“\(window)”"
        case (nil, nil): nil
        }
    }

    /// `m:ss.mmm`, for example `1:02.500`.
    static func formatTime(_ milliseconds: Int) -> String {
        let minutes = milliseconds / 60000
        let seconds = (milliseconds % 60000) / 1000
        let millis = milliseconds % 1000
        return String(format: "%d:%02d.%03d", minutes, seconds, millis)
    }
}
