import Foundation

/// The fixed text UX Review puts before a review's own sections (docs/03 §3.3, §3.5): the AI
/// instructions of an intake ticket, or the intro of a note on an existing ticket. The reviewer can
/// edit it for one review (docs/07 §7.2.3); the reviewer summary, media, and annotations that
/// follow it are always generated.
///
/// A template holds `{{name}}` placeholders, filled in when the ticket is filed. Unknown names are
/// left as typed.
public enum TicketPreamble {
    /// Which preamble: the two read differently, so each has its own template.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case newTicket
        case existingTicket
    }

    /// A value a template can use.
    public struct Variable: Equatable, Sendable {
        public var name: String
        public var meaning: String

        /// `{{name}}`, as typed in a template.
        public var placeholder: String { "{{\(name)}}" }
    }

    public static let variables: [Variable] = [
        Variable(name: "title", meaning: "the review's title"),
        Variable(name: "record", meaning: "the review.json attachment, the machine-readable record"),
        Variable(name: "schema", meaning: "the record's schema id"),
        Variable(name: "media", meaning: "every capture's attachment, comma-separated"),
        Variable(name: "counts", meaning: "for example “2 captures and 3 annotations”"),
    ]

    /// The variables `mode`'s standard template uses, in the order they first appear.
    public static func variables(for mode: Mode) -> [Variable] {
        let template = standard(mode)
        return variables
            .compactMap { variable in template.range(of: variable.placeholder).map { (variable, $0.lowerBound) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    public static func standard(_ mode: Mode) -> String {
        switch mode {
        case .newTicket: standardNewTicket
        case .existingTicket: standardExistingTicket
        }
    }

    static let standardNewTicket = """
    ## Instructions for the AI processing this ticket

    This is a **UX review intake ticket** captured with UX Review. Do not implement it directly; \
    split it into individual tickets.

    1. Read every annotation below. {{record}} is the canonical, machine-readable \
    record (schema `{{schema}}`, see the UX Review repo's `spec/review-bundle.schema.json`); \
    it holds exact shapes, intents, and time ranges.
    2. Create one ticket per distinct actionable change. Group annotations only when they describe \
    the same change; do not silently drop any annotation.
    3. In each new ticket, state the requested change and cite the annotation numbers, intents, \
    regions, and time ranges it covers. Reference the same captured media by name ({{media}}) \
    and attach those same files to it; do not recapture.
    4. Choose the category from the intent: `bug` for bug, `feature` for insert and new behavior, \
    `issue` for comment, change, remove, and move, and `investigation` for question.
    5. Add a note here listing every ticket you created, then complete this ticket.
    """

    static let standardExistingTicket = """
    ## UX review: {{title}}

    Feedback on this ticket, added with UX Review: {{counts}}. The captures and {{record}} are attached \
    to this ticket in the batch “UX review capture”; {{record}} is the canonical, machine-readable record \
    (schema `{{schema}}`, see the UX Review repo's `spec/review-bundle.schema.json`) with exact \
    shapes, intents, and time ranges. Take every annotation into account when working this ticket, and \
    cite its number when you act on it.
    """

    /// The values for `bundle`'s placeholders.
    /// - Parameter storedNames: draft file name → the name Hot Sheet stored it under, when it differs.
    public static func values(for bundle: ReviewBundle, storedNames: [String: String] = [:]) -> [String: String] {
        let bundleName = TicketComposer.bundleFilename
        let captures = bundle.media.count
        let annotations = bundle.annotations.count
        return [
            "title": bundle.title,
            "record": TicketComposer.attachmentReference(storedNames[bundleName] ?? bundleName),
            "schema": bundle.schema,
            "media": bundle.media.map { TicketComposer.attachmentReference(storedNames[$0.filename] ?? $0.filename) }
                .joined(separator: ", "),
            "counts": "\(captures) capture\(captures == 1 ? "" : "s") and \(annotations) annotation\(annotations == 1 ? "" : "s")",
        ]
    }

    /// `template` with every known `{{name}}` replaced by its value, in one pass, so a value that
    /// itself contains `{{…}}` is never expanded again.
    public static func render(_ template: String, values: [String: String]) -> String {
        var result = ""
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let name = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if let value = values[name] {
                result += value
            } else {
                result += rest[open.lowerBound ..< close.upperBound]
            }
            rest = afterOpen[close.upperBound...]
        }
        return result + rest
    }

    /// The preamble for `bundle`: `template` (or the standard one) filled in, trimmed. Empty when
    /// the reviewer cleared the template.
    public static func text(
        _ mode: Mode, for bundle: ReviewBundle, template: String? = nil, storedNames: [String: String] = [:]
    ) -> String {
        render(template ?? standard(mode), values: values(for: bundle, storedNames: storedNames))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A draft's edited preambles, kept in `<draft>/ticket-text.json` until it is filed
/// (docs/07 §7.2.3). A missing mode, file, or unreadable file means the standard text.
public struct DraftTicketText: Codable, Equatable, Sendable {
    public static let filename = "ticket-text.json"

    public var newTicket: String?
    public var existingTicket: String?

    public init(newTicket: String? = nil, existingTicket: String? = nil) {
        self.newTicket = newTicket
        self.existingTicket = existingTicket
    }

    /// The edited template for `mode`, or nil for the standard one.
    public subscript(mode: TicketPreamble.Mode) -> String? {
        get {
            switch mode {
            case .newTicket: newTicket
            case .existingTicket: existingTicket
            }
        }
        set {
            // Text equal to the standard template is the standard template: it follows later
            // changes to it instead of freezing this version.
            let value = newValue == TicketPreamble.standard(mode) ? nil : newValue
            switch mode {
            case .newTicket: newTicket = value
            case .existingTicket: existingTicket = value
            }
        }
    }

    /// The template `mode` files with: the edited one, else the standard one.
    public func template(_ mode: TicketPreamble.Mode) -> String {
        self[mode] ?? TicketPreamble.standard(mode)
    }

    public var isStandard: Bool { newTicket == nil && existingTicket == nil }

    public static func load(from directory: URL) -> DraftTicketText {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let text = try? JSONDecoder().decode(DraftTicketText.self, from: data)
        else { return DraftTicketText() }
        return text
    }

    /// Writes the file, or removes it when both preambles are standard.
    public func save(to directory: URL) throws {
        let url = directory.appendingPathComponent(Self.filename)
        if isStandard {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
