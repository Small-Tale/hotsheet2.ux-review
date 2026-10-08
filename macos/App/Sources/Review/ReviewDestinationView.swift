import SwiftUI
import UXReviewKit

/// The Submit Review window's **Ticket** section: file a new intake ticket, or add the review to
/// an existing ticket, entered by slug and looked up in the project's store so the reviewer can
/// confirm it, and choose what to add to it. Spec: docs/07-review-session.md §7.2.1, §7.2.2.
struct ReviewDestinationRows: View {
    @ObservedObject var model: ReviewSessionModel
    @State private var choosing: Bool

    /// The list starts open when part of the review is already left out (a resumed submission).
    init(model: ReviewSessionModel) {
        self.model = model
        _choosing = State(initialValue: !model.session.selection.isEverything)
    }

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
            if !session.bundle.media.isEmpty {
                DisclosureGroup(isExpanded: $choosing) {
                    ReviewSelectionList(model: model)
                } label: {
                    LabeledContent("Add", value: Self.selectionSummary(session))
                }
                .accessibilityIdentifier("session-selection")
            }
        }
    }

    /// "Everything: 3 captures, 4 annotations" or "2 of 3 captures · 3 of 4 annotations".
    static func selectionSummary(_ session: ReviewSession) -> String {
        let all = session.bundle
        let sent = session.selection.apply(to: all)
        func count(_ number: Int, _ word: String) -> String { "\(number) \(word)\(number == 1 ? "" : "s")" }
        if session.selection.isEverything {
            return "Everything: \(count(all.media.count, "capture")), \(count(all.annotations.count, "annotation"))"
        }
        let captures = "\(sent.media.count) of \(count(all.media.count, "capture"))"
        return captures + " · \(sent.annotations.count) of \(count(all.annotations.count, "annotation"))"
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

/// The captures and annotations of the review, each with a checkbox for whether it goes to the
/// existing ticket. Included annotations show the number the note gives them (§7.2.2).
private struct ReviewSelectionList: View {
    @ObservedObject var model: ReviewSessionModel

    var body: some View {
        let session = model.session
        let sent = session.selection.apply(to: session.bundle)
        let numbers = Dictionary(sent.annotations.enumerated().map { ($1.id, $0 + 1) }) { first, _ in first }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(session.bundle.media, id: \.id) { item in
                Toggle(isOn: Binding(
                    get: { session.selection.includes(media: item.id) },
                    set: { model.setIncluded(media: item.id, $0) }
                )) {
                    Text(item.filename).font(.callout.weight(.medium))
                }
                .accessibilityIdentifier("selection-\(item.id)")
                ForEach(session.bundle.annotations.filter { $0.mediaId == item.id }, id: \.id) { annotation in
                    Toggle(isOn: Binding(
                        get: { session.selection.includes(annotation) },
                        set: { model.setIncluded(annotation, $0) }
                    )) {
                        Text(Self.label(annotation, number: numbers[annotation.id]))
                            .font(.callout)
                            .foregroundStyle(numbers[annotation.id] == nil ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    .padding(.leading, 22)
                }
            }
            if model.selectionLocked {
                Text("Try Again adds the same captures and annotations as the first try.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !session.selection.isEverything {
                Button("Add Everything") { model.selectEverything() }
                    .controlSize(.small)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(model.selectionLocked)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "#2 · bug · Label is clipped", or without a number when it is left out.
    static func label(_ annotation: Annotation, number: Int?) -> String {
        var parts = [number.map { "#\($0)" } ?? "Not added"]
        parts += annotation.intents.map(\.rawValue)
        let note = annotation.note.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(note.isEmpty ? "no note" : note.replacingOccurrences(of: "\n", with: " "))
        return parts.joined(separator: " · ")
    }
}
