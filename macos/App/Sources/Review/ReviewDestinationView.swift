import SwiftUI
import UXReviewKit

/// The Submit Review window's **Ticket** section: file a new intake ticket, or add the review to
/// an existing ticket, entered by slug and looked up in the project's store so the reviewer can
/// confirm it. Spec: docs/07-review-session.md §7.2.1.
struct ReviewDestinationRows: View {
    @ObservedObject var model: ReviewSessionModel

    private var session: ReviewSession { model.session }

    var body: some View {
        Picker("Submit as", selection: Binding(get: { session.destination }, set: { model.setDestination($0) })) {
            Text("New ticket").tag(ReviewDestination.newTicket)
            Text("Add to existing ticket").tag(ReviewDestination.existingTicket)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("session-destination")

        if session.destination == .newTicket {
            Text("Files a new intake ticket. An AI working it splits it into one ticket per change.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Ticket", text: $model.ticketInput, prompt: Text("HS-ABC123, or paste a ticket reference"))
                    .accessibilityIdentifier("session-ticket")
                lookupStatus
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var lookupStatus: some View {
        switch session.ticketLookup {
        case .empty:
            Text("The review becomes a note on that ticket, with its captures and review.json attached.")
                .foregroundStyle(.secondary)
        case .noStore:
            Text("Choose a Hot Sheet project to look the ticket up.")
                .foregroundStyle(.secondary)
        case let .looking(query):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Looking up \(query.reference)…").foregroundStyle(.secondary)
            }
        case let .found(_, ticket) where ticket.acceptsReviews:
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(ticket.slug) · “\(ticket.title)”")
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(Self.statusLabel(ticket.status)).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .accessibilityElement(children: .combine)
        default:
            if let issue = session.issues.first(where: { if case .ticket = $0 { true } else { false } }) {
                Label(issue.message(in: session.bundle), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    /// `not_started` → "Not started".
    static func statusLabel(_ status: String) -> String {
        let words = status.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
