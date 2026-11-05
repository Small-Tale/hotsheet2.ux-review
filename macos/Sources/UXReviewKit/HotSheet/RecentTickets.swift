import Foundation

/// One row in the project's newest-created ticket list (HS2-19XFD1).
public struct RecentTicket: Equatable, Sendable {
    public var slug: String
    public var title: String
    public var status: String

    public init(slug: String, title: String, status: String) {
        self.slug = slug
        self.title = title
        self.status = status
    }

    /// `ls --sort created` is oldest first. Its rows have marker, slug, status, then title.
    /// Reject unknown output instead of silently presenting a broken list as an empty project.
    public static func parseList(_ output: String) throws -> [RecentTicket] {
        try Array(parseRows(output).prefix(limit))
    }

    /// The most rows a suggestion list shows (Recent and search matches alike).
    public static let limit = 10

    /// Every row of an `ls --sort created` listing, newest first, without deleted/moved tickets.
    static func parseRows(_ output: String) throws -> [RecentTicket] {
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "(no tickets)" { return [] }
        let statuses: Set<String> = ["not_started", "started", "completed", "verified", "backlog", "archive", "deleted", "moved"]
        let rows = try output.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { line in
            let parts = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count == 4, TicketReference.isSlug(String(parts[1])), statuses.contains(String(parts[2])) else {
                throw HotSheetError.unexpectedOutput(command: "ls", stdout: output)
            }
            return RecentTicket(slug: String(parts[1]), title: parts[3].trimmingCharacters(in: .whitespaces), status: String(parts[2]))
        }
        return rows.reversed().filter { !HotSheetTicket.closedStatuses.contains($0.status) }
    }
}

public extension HotSheetCLIClient {
    /// No `--open`: completed tickets still accept reviews. Cap after omitting tombstones.
    func recentTickets() throws -> [RecentTicket] {
        try RecentTicket.parseList(invoke(["ls", "--sort", "created"]).stdout)
    }
}

/// Store/request identity prevents old background reads from repopulating a new project's popup.
public struct RecentTicketSuggestions: Sendable {
    public struct Request: Equatable, Sendable {
        public let store: String
        /// What a ticket search looks for (HS2-F2VKVZ); nil for the Recent list.
        public let text: String?
        private let id = UUID()
    }

    public private(set) var request: Request?
    public private(set) var tickets: [RecentTicket] = []
    public private(set) var isLoading = false
    public private(set) var failure: String?

    public init() {}

    @discardableResult
    public mutating func begin(store: String?, text: String? = nil) -> Request? {
        request = store.map { Request(store: $0, text: text) }
        tickets = []
        failure = nil
        isLoading = request != nil
        return request
    }

    public mutating func resolve(_ request: Request, tickets: [RecentTicket], failure: String? = nil) {
        guard request == self.request, isLoading else { return }
        self.tickets = failure == nil ? tickets : []
        self.failure = failure
        isLoading = false
    }
}
