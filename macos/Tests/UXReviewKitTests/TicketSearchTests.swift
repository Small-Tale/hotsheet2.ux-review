import Foundation
import Testing
@testable import UXReviewKit

/// Searching for candidate tickets when the existing-ticket field isn't an exact match
/// (HS2-F2VKVZ, docs/07 §7.2.1).
struct TicketSearchTests {
    static func row(_ slug: String, _ title: String = "Title", _ status: String = "started") -> RecentTicket {
        RecentTicket(slug: slug, title: title, status: status)
    }

    @Test func slugFragmentsMatchAnyCaseAndToleratesWrongPrefix() {
        #expect(TicketSearch.slugMatches("HS2-F2VKVZ", fragment: "F2VK"))
        #expect(TicketSearch.slugMatches("HS2-F2VKVZ", fragment: "f2vkvz"))
        #expect(TicketSearch.slugMatches("HS2-F2VKVZ", fragment: "hs2-f2v"))
        #expect(TicketSearch.slugMatches("HS2-F2VKVZ", fragment: "HS-F2VKVZ"))
        #expect(TicketSearch.slugMatches("HS2-F2VKVZ", fragment: "HS-F2V"))
        #expect(TicketSearch.slugMatches("HS2-F2VKVZ", fragment: "VZ"))
        // Too short, too short a suffix, punctuation or spaces, and a different suffix.
        #expect(!TicketSearch.slugMatches("HS2-F2VKVZ", fragment: "F"))
        #expect(!TicketSearch.slugMatches("HS2-F2VKVZ", fragment: "HS-F2"))
        #expect(!TicketSearch.slugMatches("HS2-F2VKVZ", fragment: "F2 VK"))
        #expect(!TicketSearch.slugMatches("HS2-F2VKVZ", fragment: "F2VK?"))
        #expect(!TicketSearch.slugMatches("HS2-F2VKVZ", fragment: "HS2-ABCDEF"))
        #expect(!TicketSearch.slugMatches("HS2-F2VKVZ", fragment: "XF2VKVZ-Q"))
        #expect(!TicketSearch.slugMatches("HS2-F2VKVZ", fragment: "-F2Q"))
    }

    @Test func normalizedTrimsFlattensAndRejectsShortText() {
        #expect(TicketSearch.normalized("  ") == nil)
        #expect(TicketSearch.normalized(" a\n") == nil)
        #expect(TicketSearch.normalized(" ab ") == "ab")
        #expect(TicketSearch.normalized("two\nlines") == "two lines")
    }

    @Test func mergePutsSlugMatchesFirstWithoutRepeatsAndCaps() {
        let all = [Self.row("HS-ZZ0009"), Self.row("HS-AB0008"), Self.row("HS-AB0007"), Self.row("HS-CC0006")]
        let text = [Self.row("HS-CC0006"), Self.row("HS-AB0007")]
        #expect(TicketSearch.merge("ab00", all: all, textMatches: text).map(\.slug) == ["HS-AB0008", "HS-AB0007", "HS-CC0006"])
        #expect(TicketSearch.merge("words here", all: all, textMatches: text).map(\.slug) == ["HS-CC0006", "HS-AB0007"])
        #expect(TicketSearch.merge("nothing", all: all, textMatches: []).isEmpty)
        let many = (0 ..< 15).map { Self.row("HS-AB\(String(format: "%04d", 20 - $0))") }
        let capped = TicketSearch.merge("HS-AB", all: many, textMatches: many.reversed())
        #expect(capped.count == RecentTicket.limit)
        #expect(capped.first?.slug == "HS-AB0020")
        #expect(capped.last?.slug == "HS-AB0011")
    }

    static func client(_ runner: FakeRunner) -> HotSheetCLIClient {
        HotSheetCLIClient(
            executable: URL(fileURLWithPath: "/bin/hotsheet-cli"), storePath: URL(fileURLWithPath: "/stores/chosen.hs2"),
            runner: runner, baseEnvironment: [:]
        )
    }

    @Test func transportListsForSlugsThenSearchesTextAsOneArgument() throws {
        let runner = FakeRunner(results: [
            .init(exitCode: 0, stdout: " ● HS2-OLD001 started -dash in title\n ● HS2-NEW002 deleted Gone\n", stderr: ""),
            .init(exitCode: 0, stdout: " ● HS2-OLD001 started -dash in title\n", stderr: ""),
        ])
        let found = try Self.client(runner).searchTickets("  -dash  ")
        #expect(found == [Self.row("HS2-OLD001", "-dash in title")])
        let prefix = ["-C", "/stores/chosen.hs2", "ls", "--actor-role=human", "--actor-id=ux-review", "--sort", "created"]
        #expect(runner.calls.map(\.arguments) == [prefix, prefix + ["--text=-dash"]])
    }

    @Test func transportSkipsShortTextAndReportsFailuresAndBadOutput() throws {
        let idle = FakeRunner(results: [])
        #expect(try Self.client(idle).searchTickets(" x ").isEmpty)
        #expect(idle.calls.isEmpty)

        let failedList = FakeRunner(results: [.init(exitCode: 1, stdout: "", stderr: "store unavailable")])
        #expect(throws: HotSheetError.commandFailed(command: "ls", exitCode: 1, stderr: "store unavailable")) {
            try Self.client(failedList).searchTickets("words")
        }
        let failedText = FakeRunner(results: [
            .init(exitCode: 0, stdout: "(no tickets)\n", stderr: ""),
            .init(exitCode: 2, stdout: "", stderr: "bad flag"),
        ])
        #expect(throws: HotSheetError.commandFailed(command: "ls", exitCode: 2, stderr: "bad flag")) {
            try Self.client(failedText).searchTickets("words")
        }
        let garbled = FakeRunner(results: [
            .init(exitCode: 0, stdout: "(no tickets)\n", stderr: ""),
            .init(exitCode: 0, stdout: "Unexpected\n", stderr: ""),
        ])
        #expect(throws: HotSheetError.unexpectedOutput(command: "ls", stdout: "Unexpected\n")) {
            try Self.client(garbled).searchTickets("words")
        }
    }

    /// Search text for every lookup state, destination, and target.
    @Test func searchTextFollowsTheLookupState() {
        typealias Start = ExistingTicketSessionTests.Start
        let expected: [Start: String?] = [
            .empty: nil, .unrecognized: "junk", .looking: nil, .found: nil, .notFound: "HS-1ABC", .failed: nil, .noStore: nil,
        ]
        for start in Start.allCases {
            var session = ExistingTicketSessionTests.session(in: start)
            #expect(session.ticketSearchText == expected[start] ?? nil, "\(start)")
            session.setDestination(.newTicket)
            #expect(session.ticketSearchText == nil, "\(start) new ticket")
            session.setDestination(.existingTicket)
            #expect(session.ticketSearchText == expected[start] ?? nil, "\(start) back to existing")
        }
        var session = ExistingTicketSessionTests.session(in: .unrecognized)
        session.editTicket(" q ")
        #expect(session.ticketSearchText == nil, "One character isn't searched")
        #expect(TicketIssue.unrecognized(" q ").message == "“q” isn't a ticket. Enter a slug such as HS-ABC123.")
        session.editTicket("account settings")
        #expect(session.ticketSearchText == "account settings")
        session.setTarget(ExistingTicketSessionTests.noStore)
        #expect(session.ticketSearchText == nil, "No store to search")
        session.setTarget(ExistingTicketSessionTests.storeB)
        #expect(session.ticketSearchText == "account settings", "Refilled with another store")
        // Typing an exact reference ends the search until its lookup says there's no such ticket.
        session.editTicket("HS-2XYZ")
        #expect(session.ticketSearchText == nil)
        session.resolveLookup(TicketQuery(reference: "HS-2XYZ", storePath: "/b.hs2"), .success(nil))
        #expect(session.ticketSearchText == "HS-2XYZ")
        session.editTicket("")
        #expect(session.ticketSearchText == nil)
    }

    @Test func searchRequestsAreScopedToTheirText() throws {
        var state = RecentTicketSuggestions()
        let rows = [Self.row("HS-AB0001")]
        let firstRequest = state.begin(store: "a", text: "acc")
        let first = try #require(firstRequest)
        let secondRequest = state.begin(store: "a", text: "account")
        let second = try #require(secondRequest)
        #expect(first.text == "acc" && second.text == "account" && first != second)
        state.resolve(first, tickets: rows)
        #expect(state.isLoading && state.tickets.isEmpty, "Results for older text are ignored")
        state.resolve(second, tickets: rows)
        #expect(state.tickets == rows && state.request?.text == "account")
        #expect(state.begin(store: "a")?.text == nil, "Recent requests carry no text")
    }
}

extension HotSheetEndToEndTests {
    @Test(.enabled(if: cli != nil, "hotsheet-cli not installed"), .timeLimit(.minutes(2)))
    func ticketSearchFindsSlugFragmentsAndTextInARealStore() throws {
        let cli = try #require(Self.cli)
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var env = ProcessInfo.processInfo.environment
        env["HOTSHEET_ACTOR_ROLE"] = nil
        env["HOTSHEET_ACTOR_ID"] = nil
        let store = root.appendingPathComponent("search.hs2")
        let initialized = try SystemProcessRunner().run(
            executable: cli, arguments: ["-C", store.path, "init"], environment: env, currentDirectory: nil
        )
        try #require(initialized.exitCode == 0)
        let client = HotSheetCLIClient(executable: cli, storePath: store, baseEnvironment: env)
        let settings = try client.createTicket(NewTicket(title: "Account settings page", details: ""))
        let details = try client.createTicket(NewTicket(title: "Sidebar", details: "Loses the account settings selection"))
        let noted = try client.createTicket(NewTicket(title: "Avatar upload", details: ""))
        try client.addNote("Also check -dash flags in account settings", to: noted)
        let deleted = try client.createTicket(NewTicket(title: "Account settings, deleted", details: ""))
        try client.moveToTrash(deleted)

        // Title, details, and note text, newest first; the deleted ticket is left out.
        #expect(try client.searchTickets("ACCOUNT SETTINGS").map(\.slug) == [noted, details, settings])
        #expect(try client.searchTickets("-dash").map(\.slug) == [noted])
        // A slug fragment, and a slug with the wrong prefix, find the ticket.
        let suffix = try #require(settings.split(separator: "-").last)
        #expect(try client.searchTickets(String(suffix.prefix(4)).lowercased()).first?.slug == settings)
        #expect(try client.searchTickets("XX-\(suffix)").map(\.slug) == [settings])
        #expect(try client.searchTickets("zebra stripes").isEmpty)
        // A candidate resolves through the ordinary lookup.
        #expect(try client.findTicket(settings)?.title == "Account settings page")
    }
}
