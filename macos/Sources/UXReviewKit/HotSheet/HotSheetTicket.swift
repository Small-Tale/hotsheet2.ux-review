import Foundation

/// A ticket that already exists in a store, as `hotsheet-cli show` prints it: the review can be
/// added to it instead of filing a new intake ticket. Spec: docs/03-hotsheet-integration.md §3.5.
public struct HotSheetTicket: Codable, Equatable, Sendable {
    /// The ticket's ULID.
    public var id: String
    public var slug: String
    public var title: String
    /// `not_started`, `started`, `completed`, …, `deleted`, `moved`.
    public var status: String
    /// The ticket's Markdown file in the store, when it was found on disk.
    public var file: String?

    public init(id: String, slug: String, title: String, status: String, file: String? = nil) {
        self.id = id
        self.slug = slug
        self.title = title
        self.status = status
        self.file = file
    }

    /// Statuses whose ticket no longer takes new work: a deleted ticket sits in the Trash and a
    /// moved one is a tombstone pointing at another store.
    public static let closedStatuses: Set<String> = ["deleted", "moved"]

    public var acceptsReviews: Bool { !Self.closedStatuses.contains(status) }

    public var createdTicket: CreatedTicket { CreatedTicket(slug: slug, file: file) }

    /// Reads the YAML front matter `hotsheet-cli show` prints (`id`, `slug`, `title`, `status`).
    /// Nil when the output has no front matter or lacks the id or slug.
    public static func parseShow(_ output: String) -> HotSheetTicket? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            // Only top-level scalar keys; nested lists (attachments, claims) are indented.
            guard let first = line.first, first != " ", first != "-", let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            guard ["id", "slug", "title", "status"].contains(key), fields[key] == nil else { continue }
            fields[key] = YAMLScalar.parse(String(line[line.index(after: colon)...]))
        }
        guard let id = fields["id"], !id.isEmpty, let slug = fields["slug"], !slug.isEmpty else { return nil }
        return HotSheetTicket(id: id, slug: slug, title: fields["title"] ?? "", status: fields["status"] ?? "")
    }

    /// Where Hot Sheet 2 keeps a ticket's file: `<store>/tickets/<last two ULID characters>/<ULID>.md`.
    public static func ticketFile(id: String, store: URL) -> URL {
        store.appendingPathComponent("tickets", isDirectory: true)
            .appendingPathComponent(String(id.suffix(2)), isDirectory: true)
            .appendingPathComponent("\(id).md")
    }
}

/// The single-line YAML scalars Hot Sheet writes in front matter: plain, 'single-quoted', or
/// "double-quoted" (with backslash escapes).
enum YAMLScalar {
    static func parse(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return unescape(String(value.dropFirst().dropLast()))
        }
        // A plain scalar ends before a ` #` comment.
        if let comment = value.range(of: " #") { return String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return value
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let escaped = iterator.next() else {
                result.append(character)
                continue
            }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "u":
                let hex = String((0 ..< 4).compactMap { _ in iterator.next() })
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { result.unicodeScalars.append(scalar) }
            default: result.append(escaped)
            }
        }
        return result
    }
}

/// Turns what a reviewer typed or pasted into a ticket reference `hotsheet-cli` accepts: a slug
/// (`HS2-ABC123`, any case), a ULID, a ticket file path or link ending in `<ULID>.md`, or text
/// that contains a slug (a line copied from `hotsheet-cli ls`, `HS-ABC123: title`, a URL).
public enum TicketReference {
    /// The slug (uppercased) or ULID, or nil when the text holds neither.
    public static func parse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A ticket file: `…/tickets/8D/01M4….md`.
        let last = (trimmed as NSString).lastPathComponent
        if last.lowercased().hasSuffix(".md") {
            let stem = String(last.dropLast(3))
            if isULID(stem) { return stem.uppercased() }
        }
        let tokens = trimmed.split { !$0.isASCII || !($0.isLetter || $0.isNumber || $0 == "-") }.map(String.init)
        if tokens.count == 1, isULID(tokens[0]) || isSlug(tokens[0]) { return tokens[0].uppercased() }
        // Inside other text, a slug is written the way Hot Sheet prints it (uppercase) or has a
        // digit, so words such as `ux-review` or `follow-up` don't count.
        let slugs = tokens.filter(isSlug)
        let match = slugs.first { $0 == $0.uppercased() } ?? slugs.first { $0.contains(where: \.isNumber) }
        return match?.uppercased()
    }

    /// `PREFIX-SUFFIX`: a letter-led prefix of 1–16 letters and digits, and 4–16 letters and digits.
    static func isSlug(_ token: String) -> Bool {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = parts.first, let suffix = parts.last,
              (1 ... 16).contains(prefix.count), (4 ... 16).contains(suffix.count),
              prefix.first?.isLetter == true,
              prefix.allSatisfy({ $0.isLetter || $0.isNumber }),
              suffix.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return false }
        return true
    }

    /// A 26-character Crockford base-32 ULID.
    static func isULID(_ token: String) -> Bool {
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return token.count == 26 && token.uppercased().allSatisfy { alphabet.contains($0) }
    }
}
