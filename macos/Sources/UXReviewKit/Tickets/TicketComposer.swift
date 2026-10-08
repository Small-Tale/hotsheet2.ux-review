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

    /// - Parameter preamble: the reviewer's edited instructions template (docs/07 §7.2.3); nil
    ///   for the standard one.
    public static func compose(_ bundle: ReviewBundle, preamble: String? = nil) -> ComposedReview {
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
            details: details(for: bundle, preamble: preamble),
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
        }
        if bundle.media.contains(where: { $0.hasAudio == true }) {
            lines += ["", audioHint]
        }
        if bundle.media.contains(where: { $0.scaledFrom != nil }) {
            lines += ["", scaledHint]
        }
        return lines.joined(separator: "\n")
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
