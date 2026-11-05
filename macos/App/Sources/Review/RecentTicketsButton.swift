import SwiftUI
import UXReviewKit

/// A bounded, keyboard-accessible popup; manual ticket references remain available beside it.
struct RecentTicketsButton: View {
    @ObservedObject var model: ReviewSessionModel
    @State private var showing = false

    var body: some View {
        Button {
            model.loadRecentTickets()
            showing.toggle()
        } label: {
            Label("Recent", systemImage: "clock.arrow.circlepath")
        }
        .accessibilityLabel("Recent tickets")
        .accessibilityIdentifier("session-recent-tickets")
        .help("Choose from this project's 10 newest tickets")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent tickets").font(.headline)
                Text("Newest first · Selected project").font(.caption).foregroundStyle(.secondary)
                if model.recentTickets.isLoading {
                    ProgressView("Loading tickets…").controlSize(.small)
                } else if model.session.target.storePath == nil {
                    Text("Choose a Hot Sheet project first.")
                } else if model.recentTickets.failure != nil {
                    Text("Couldn't load recent tickets. Enter a reference or try again.")
                    Button("Try Again") { model.loadRecentTickets() }
                } else if model.recentTickets.tickets.isEmpty {
                    Text("No recent tickets in this project. You can still paste a reference.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.recentTickets.tickets, id: \.slug) { ticket in
                                TicketSuggestionRow(ticket: ticket) {
                                    model.chooseRecentTicket(ticket)
                                    showing = false
                                }
                                .accessibilityIdentifier("recent-ticket-\(ticket.slug)")
                            }
                        }
                    }
                    .frame(maxHeight: 340)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(width: 340, alignment: .leading)
            .accessibilityIdentifier("recent-ticket-popup")
        }
    }
}

/// One suggested ticket: its title, then slug and status. Recent and the search matches share it.
struct TicketSuggestionRow: View {
    var ticket: RecentTicket
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ticket.title).lineLimit(2)
                Text("\(ticket.slug) · \(ReviewDestinationRows.statusLabel(ticket.status))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Candidates for text in the ticket field that isn't an exact reference (HS2-F2VKVZ, docs/07
/// §7.2.1): slug fragments, then title, details, and note matches. Choosing one fills the field.
struct TicketMatches: View {
    @ObservedObject var model: ReviewSessionModel
    var text: String

    var body: some View {
        let search = model.ticketSearch
        VStack(alignment: .leading, spacing: 4) {
            Text("Matching tickets").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if search.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Searching for “\(text)”…").foregroundStyle(.secondary)
                }
                .font(.caption)
            } else if search.failure != nil {
                HStack(spacing: 8) {
                    Text("Couldn't search this project's tickets.").font(.caption).foregroundStyle(.secondary)
                    Button("Try Again") { model.retryTicketSearch() }
                        .controlSize(.small)
                        .accessibilityIdentifier("ticket-search-retry")
                }
            } else if search.tickets.isEmpty {
                Text("No tickets match “\(text)”.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(search.tickets, id: \.slug) { ticket in
                            TicketSuggestionRow(ticket: ticket) { model.chooseSearchedTicket(ticket) }
                                .accessibilityIdentifier("ticket-match-\(ticket.slug)")
                        }
                    }
                }
                .frame(maxHeight: 190)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternarySystemFill)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ticket-matches")
    }
}
