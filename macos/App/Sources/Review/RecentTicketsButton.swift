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
                                Button {
                                    model.chooseRecentTicket(ticket)
                                    showing = false
                                } label: {
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
