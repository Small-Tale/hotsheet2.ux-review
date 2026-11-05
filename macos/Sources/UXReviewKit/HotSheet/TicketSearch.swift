import Foundation

/// Candidate tickets for text in the existing-ticket field that isn't an exact reference
/// (HS2-F2VKVZ, docs/07 §7.2.1): a slug fragment, a slug that doesn't exist, or words from a
/// ticket's title, details, or notes.
public enum TicketSearch {
    /// The shortest typed text that is searched.
    public static let minimumLength = 2

    /// The text to search for, or nil when the text is too short to search.
    public static func normalized(_ text: String) -> String? {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return flat.count >= minimumLength ? flat : nil
    }

    /// Whether `slug` matches a slug fragment: `F2VK`, `hs2-f2v`, or a wrong prefix such as
    /// `HS-F2VKVZ` (same suffix). Text with spaces or other punctuation never matches a slug.
    public static func slugMatches(_ slug: String, fragment text: String) -> Bool {
        let query = text.uppercased()
        guard query.count >= minimumLength, query.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return false
        }
        let slug = slug.uppercased()
        if slug.contains(query) { return true }
        guard let dash = query.firstIndex(of: "-"), let slugDash = slug.firstIndex(of: "-") else { return false }
        let suffix = query[query.index(after: dash)...]
        return suffix.count >= 3 && slug[slug.index(after: slugDash)...].hasPrefix(suffix)
    }

    /// Slug matches first, then text matches, each newest first, without repeats, at most 10.
    /// - Parameters:
    ///   - all: every listed ticket, newest first.
    ///   - textMatches: the tickets whose title, details, or notes contain the text, newest first.
    public static func merge(_ text: String, all: [RecentTicket], textMatches: [RecentTicket]) -> [RecentTicket] {
        var seen = Set<String>()
        let ordered = all.filter { slugMatches($0.slug, fragment: text) } + textMatches
        return Array(ordered.filter { seen.insert($0.slug).inserted }.prefix(RecentTicket.limit))
    }
}

public extension HotSheetCLIClient {
    /// Candidate tickets for `text` (HS2-F2VKVZ): `ls --sort created` for slug fragments, and
    /// `ls --sort created --text=<text>` for title, details, and notes (the CLI's `--text` doesn't
    /// look at slugs). `--text=` keeps text that starts with `-` from reading as an option.
    func searchTickets(_ text: String) throws -> [RecentTicket] {
        guard let query = TicketSearch.normalized(text) else { return [] }
        let all = try RecentTicket.parseRows(invoke(["ls", "--sort", "created"]).stdout)
        let textMatches = try RecentTicket.parseRows(invoke(["ls", "--sort", "created", "--text=\(query)"]).stdout)
        return TicketSearch.merge(query, all: all, textMatches: textMatches)
    }
}

public extension ReviewSession {
    /// What to search for candidates (HS2-F2VKVZ): the typed text that isn't a reference, or a
    /// reference with no such ticket. Nil while another destination is chosen, the session isn't
    /// editable, there's no store, or the text is an exact match (or still being looked up).
    var ticketSearchText: String? {
        guard destination == .existingTicket, isEditable, target.problem == nil, target.storePath != nil else { return nil }
        switch ticketLookup {
        case let .unrecognized(text): return TicketSearch.normalized(text)
        case let .notFound(query): return TicketSearch.normalized(query.reference)
        case .empty, .noStore, .looking, .found, .failed: return nil
        }
    }
}
