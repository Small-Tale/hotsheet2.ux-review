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

    /// The Markdown note that adds a review to an existing ticket instead of filing an intake
    /// ticket (docs/03 §3.5): the review's title, what was attached, then the same sections as an
    /// intake ticket body, one heading level deeper. No splitting instructions: the review is
    /// feedback on this ticket.
    /// - Parameter storedNames: draft file name → the name Hot Sheet stored it under, for files
    ///   it renamed because the ticket already had one by that name.
    public static func note(for bundle: ReviewBundle, storedNames: [String: String] = [:]) -> String {
        let captures = bundle.media.count
        let annotations = bundle.annotations.count
        let counts = "\(captures) capture\(captures == 1 ? "" : "s") and \(annotations) annotation\(annotations == 1 ? "" : "s")"
        let record = attachmentReference(storedNames[bundleFilename] ?? bundleFilename)
        let intro = """
        ## UX review: \(bundle.title)

        Feedback on this ticket, added with UX Review: \(counts). The captures and \(record) are attached \
        to this ticket in the batch “UX review capture”; \(record) is the canonical, machine-readable record \
        (schema `\(bundle.schema)`, see the UX Review repo's `spec/review-bundle.schema.json`) with exact \
        shapes, intents, and time ranges. Take every annotation into account when working this ticket, and \
        cite its number when you act on it.
        """
        return ([intro] + reviewSections(bundle, heading: "###", storedNames: storedNames)).joined(separator: "\n\n") + "\n"
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

        lines += reviewSections(bundle, heading: "##", storedNames: [:])
        return lines.joined(separator: "\n\n") + "\n"
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
            var meta = "- Shape: \(annotation.shape.kind); region (0–10000): x \(bounds.x), y \(bounds.y), "
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
            if let duration = item.durationMs { line += ", \(formatTime(duration))" }
            if item.hasAudio == true { line += ", with audio" }
            line += ")"
            if let source = sourceLabel(item.context) { line += ", from \(source)" }
            if stored != item.filename { line += "; stored under this name, `\(bundleFilename)` calls it \(codeSpan(item.filename))" }
            lines.append(line)
        }
        if bundle.media.contains(where: { $0.hasAudio == true }) {
            lines += ["", audioHint]
        }
        return lines.joined(separator: "\n")
    }

    /// Follows the media list when a video has sound, so the agent doesn't treat it as silent.
    static let audioHint = "Videos marked “with audio” have a sound track, usually the reviewer's spoken narration. "
        + "Listen to or transcribe it: it can explain the annotations or ask for changes they don't show."

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
