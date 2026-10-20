import Foundation
import Testing
@testable import UXReviewKit

struct RecentTicketsTests {
    @Test func listingIsNewestFirstCappedAfterExcludingTombstones() throws {
        let rows = (0 ..< 15).map { index in
            " *● HS2-ABC\(String(format: "%03d", index))   \(index >= 13 ? "deleted" : "completed")   Ticket \(index): it's “ready”"
        }.joined(separator: "\n") + "\n ● HS2-MOVED0 moved A tombstone\n"
        let tickets = try RecentTicket.parseList(rows)
        #expect(tickets.count == 10)
        #expect(tickets.first == RecentTicket(slug: "HS2-ABC012", title: "Ticket 12: it's “ready”", status: "completed"))
        #expect(tickets.last?.slug == "HS2-ABC003")
        #expect(try RecentTicket.parseList(" \n").isEmpty)
        #expect(try RecentTicket.parseList("(no tickets)\n").isEmpty)
        #expect(try RecentTicket.parseList(" ● HS2-ABC123 not_started Long   spaced title").first?.title == "Long   spaced title")
    }

    @Test func malformedListingsFailExplicitly() {
        for output in ["Unexpected format", " ● invalid started Title", " ● HS2-ABC123 unknown Title", " ● HS2-ABC123 started"] {
            #expect(throws: HotSheetError.unexpectedOutput(command: "ls", stdout: output)) {
                try RecentTicket.parseList(output)
            }
        }
    }

    @Test func transportUsesSelectedStoreAndNoOpenFilterOrPrematureLimit() throws {
        let runner = FakeRunner(results: [.init(exitCode: 0, stdout: " ● HS2-ABC123 verified Shipped ticket\n", stderr: "")])
        let client = HotSheetCLIClient(
            executable: URL(fileURLWithPath: "/bin/hotsheet-cli"), storePath: URL(fileURLWithPath: "/stores/chosen.hs2"),
            runner: runner, baseEnvironment: [:]
        )
        #expect(try client.recentTickets().first?.slug == "HS2-ABC123")
        #expect(runner.calls.first?.arguments == [
            "-C", "/stores/chosen.hs2", "ls", "--actor-role=human", "--actor-id=ux-review", "--sort", "created",
        ])
        let failed = FakeRunner(results: [.init(exitCode: 1, stdout: "", stderr: "store unavailable")])
        #expect(throws: HotSheetError.commandFailed(command: "ls", exitCode: 1, stderr: "store unavailable")) {
            try HotSheetCLIClient(executable: client.executable, storePath: client.storePath, runner: failed).recentTickets()
        }
    }

    @Test func suggestionsRejectStaleRepeatedAndCrossProjectResponses() throws {
        var state = RecentTicketSuggestions()
        let tickets = [RecentTicket(slug: "HS2-ABC123", title: "Example", status: "started")]
        let firstRequest = state.begin(store: "first")
        let first = try #require(firstRequest)
        #expect(state.isLoading && state.tickets.isEmpty && state.failure == nil)
        let secondRequest = state.begin(store: "second")
        let second = try #require(secondRequest)
        state.resolve(first, tickets: tickets)
        #expect(state.isLoading && state.tickets.isEmpty)
        state.resolve(second, tickets: [], failure: "Unavailable")
        #expect(!state.isLoading && state.failure == "Unavailable")
        state.resolve(second, tickets: tickets)
        #expect(state.tickets.isEmpty)
        let retryRequest = state.begin(store: "second")
        let retry = try #require(retryRequest)
        #expect(state.failure == nil)
        state.resolve(second, tickets: tickets)
        #expect(state.isLoading)
        state.resolve(retry, tickets: tickets)
        #expect(state.tickets == tickets && !state.isLoading)
        let reloadRequest = state.begin(store: "second")
        let reload = try #require(reloadRequest)
        #expect(state.tickets.isEmpty)
        state.resolve(reload, tickets: [])
        #expect(state.tickets.isEmpty && !state.isLoading)
        let refillRequest = state.begin(store: "second")
        let refill = try #require(refillRequest)
        state.resolve(refill, tickets: tickets)
        #expect(state.tickets == tickets)
        let cleared = state.begin(store: nil)
        #expect(cleared == nil)
        state.resolve(refill, tickets: tickets)
        #expect(state.tickets.isEmpty && !state.isLoading && state.failure == nil && state.request == nil)
    }
}

extension HotSheetEndToEndTests {
    @Test(.enabled(if: cli != nil, "hotsheet-cli not installed"), .timeLimit(.minutes(2)))
    func recentTicketsUseRealCreationOrderAndSelectedProject() throws {
        let cli = try #require(Self.cli)
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var env = ProcessInfo.processInfo.environment
        env["HOTSHEET_ACTOR_ROLE"] = nil
        env["HOTSHEET_ACTOR_ID"] = nil
        let runner = SystemProcessRunner()
        func client(_ name: String) throws -> HotSheetCLIClient {
            let store = root.appendingPathComponent(name + ".hs2")
            let initialized = try runner.run(
                executable: cli,
                arguments: ["-C", store.path, "init"],
                environment: env,
                currentDirectory: nil
            )
            try #require(initialized.exitCode == 0)
            return HotSheetCLIClient(executable: cli, storePath: store, baseEnvironment: env)
        }
        let first = try client("first")
        let second = try client("second")
        #expect(try first.recentTickets().isEmpty)
        var slugs: [String] = []
        for index in 0 ..< 12 {
            slugs.append(try first.createTicket(NewTicket(title: "Recent \(index): it's “ready”", details: "")))
        }
        let deleted = try first.createTicket(NewTicket(title: "Deleted newest", details: ""))
        try first.moveToTrash(deleted)
        // Updating an old ticket doesn't change newest-created ordering.
        try first.addNote("An older ticket was updated", to: slugs[0])
        let other = try second.createTicket(NewTicket(title: "Other project", details: ""))
        let recent = try first.recentTickets()
        #expect(recent.map(\.slug) == Array(slugs.reversed().prefix(10)))
        #expect(recent.first?.title == "Recent 11: it's “ready”")
        #expect(try second.recentTickets().map(\.slug) == [other])
        #expect(try first.findTicket(#require(recent.first?.slug))?.title == recent.first?.title)
    }
}
