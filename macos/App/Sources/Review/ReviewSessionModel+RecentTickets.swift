import Foundation
import UXReviewKit

extension ReviewSessionModel {
    /// Runs one ticket listing with `hotsheet-cli` in `store` (blocking; call it off the main thread).
    nonisolated static func listTickets(
        _ cli: String, _ store: String, _ list: (HotSheetCLIClient) throws -> [RecentTicket]
    ) -> Result<[RecentTicket], SubmissionFailure> {
        do {
            return try .success(list(HotSheetCLIClient(executable: URL(fileURLWithPath: cli), storePath: URL(fileURLWithPath: store))))
        } catch {
            return .failure(SubmissionFailure(message: ReviewSubmitter.describe(error)))
        }
    }

    /// Refresh whenever the popup opens; project changes clear its previous rows immediately.
    func loadRecentTickets() {
        recentTicketsTask?.cancel()
        guard session.destination == .existingTicket, let cli = session.target.cliPath,
              let request = recentTickets.begin(store: session.target.storePath)
        else {
            recentTickets.begin(store: nil)
            return
        }
        let load = recentTicketLoader
        recentTicketsTask = Task { [weak self] in
            let result = await Task.detached { load(cli, request.store) }.value
            guard !Task.isCancelled, let self else { return }
            switch result {
            case let .success(tickets): recentTickets.resolve(request, tickets: tickets)
            case let .failure(error): recentTickets.resolve(request, tickets: [], failure: error.message)
            }
        }
    }

    /// Searches for candidates while the field holds text that isn't an exact match
    /// (HS2-F2VKVZ), 0.3 s after typing stops; clears them otherwise. The same text in the same
    /// store keeps its results, and a response for older text or another store is ignored.
    func scheduleTicketSearch() {
        let store = session.target.storePath
        guard let text = session.ticketSearchText, let cli = session.target.cliPath, let store else {
            guard ticketSearch.request != nil else { return }
            ticketSearchTask?.cancel()
            ticketSearch.begin(store: nil)
            return
        }
        if let current = ticketSearch.request, current.store == store, current.text == text { return }
        ticketSearchTask?.cancel()
        guard let request = ticketSearch.begin(store: store, text: text) else { return }
        let search = ticketSearcher
        ticketSearchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lookupDelay)
            guard !Task.isCancelled else { return }
            let result = await Task.detached { search(cli, store, text) }.value
            guard !Task.isCancelled, let self else { return }
            switch result {
            case let .success(tickets): ticketSearch.resolve(request, tickets: tickets)
            case let .failure(error): ticketSearch.resolve(request, tickets: [], failure: error.message)
            }
        }
    }

    /// Fills the field with a candidate; the ordinary lookup then confirms it.
    func chooseSearchedTicket(_ ticket: RecentTicket) {
        guard session.isEditable, ticketSearch.tickets.contains(ticket),
              ticketSearch.request?.store == session.target.storePath else { return }
        ticketInput = ticket.slug
    }

    /// Previews resolve the waiting search without running `hotsheet-cli`.
    func previewTicketSearch(_ result: Result<[RecentTicket], SubmissionFailure>) {
        ticketSearchTask?.cancel()
        guard let request = ticketSearch.request else { return }
        switch result {
        case let .success(tickets): ticketSearch.resolve(request, tickets: tickets)
        case let .failure(error): ticketSearch.resolve(request, tickets: [], failure: error.message)
        }
    }

    /// Runs the search again after it failed.
    func retryTicketSearch() {
        ticketSearch.begin(store: nil)
        scheduleTicketSearch()
    }

    func chooseRecentTicket(_ ticket: RecentTicket) {
        guard session.isEditable, recentTickets.tickets.contains(ticket),
              recentTickets.request?.store == session.target.storePath else { return }
        // Use the ordinary lookup: a ticket may have changed since the popup loaded.
        ticketInput = ticket.slug
    }
}
