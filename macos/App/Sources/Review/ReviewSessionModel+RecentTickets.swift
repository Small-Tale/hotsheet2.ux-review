import Foundation
import UXReviewKit

extension ReviewSessionModel {
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

    func chooseRecentTicket(_ ticket: RecentTicket) {
        guard session.isEditable, recentTickets.tickets.contains(ticket),
              recentTickets.request?.store == session.target.storePath else { return }
        // Use the ordinary lookup: a ticket may have changed since the popup loaded.
        ticketInput = ticket.slug
    }
}
