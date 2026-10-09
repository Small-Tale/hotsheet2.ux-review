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
        TicketTextBox(model: model)
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

/// The preamble UX Review puts before the review's own sections (§7.2.3): shown rendered, values
/// filled in; a click edits the template, where placeholders stay `{{name}}` until Done. It follows
/// the New / Existing switch, and edits last for this review only.
struct TicketTextBox: View {
    @ObservedObject var model: ReviewSessionModel
    @State private var editing: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    init(model: ReviewSessionModel, editing: Bool = false) {
        self.model = model
        _editing = State(initialValue: editing)
        _text = State(initialValue: editing ? model.preambleTemplate : "")
    }

    private var editable: Bool { model.session.isEditable }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Ticket text").font(.callout.weight(.medium))
                if !model.preambleIsStandard {
                    Text("Edited")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Edited for this review")
                }
                Spacer()
                if !model.preambleIsStandard || editing {
                    Button("Reset to Standard") {
                        model.setPreamble(nil)
                        text = model.preambleTemplate
                    }
                    .disabled(model.preambleIsStandard || !editable)
                    .accessibilityIdentifier("session-ticket-text-reset")
                }
                Button(editing ? "Done" : "Edit") { editing ? finish() : start() }
                    .disabled(!editable)
                    .accessibilityIdentifier("session-ticket-text-toggle")
            }
            .controlSize(.small)

            if editing {
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(minHeight: 140, idealHeight: 200, maxHeight: 260)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6)))
                    .focused($focused)
                    .onChange(of: text) { _, new in model.setPreamble(new) }
                    .accessibilityLabel("Ticket text template")
                    .accessibilityIdentifier("session-ticket-text-editor")
                Text(Self.placeholderHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button(action: start) {
                    MarkdownPreview(markdown: model.preambleText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternarySystemFill)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!editable)
                .help("Click to edit the text added before the annotations")
                .accessibilityLabel("Ticket text")
                .accessibilityValue(model.preambleText)
                .accessibilityHint("Edits the text added before the annotations")
                .accessibilityIdentifier("session-ticket-text")
                Text("Added before the reviewer summary and annotations, which are always included. Click to edit it for this review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
        // The other destination has its own text.
        .onChange(of: model.preambleMode) { _, _ in if editing { text = model.preambleTemplate } }
    }

    private func start() {
        guard editable else { return }
        text = model.preambleTemplate
        editing = true
        focused = true
    }

    private func finish() {
        model.setPreamble(text)
        editing = false
    }

    /// "Placeholders: {{title}} the review's title · …".
    static let placeholderHelp = "Placeholders: "
        + TicketPreamble.variables.map { "\($0.placeholder) \($0.meaning)" }.joined(separator: " · ")
        + ". Leave it empty to add no text."
}

/// Short Markdown shown rendered: headings, numbered and bulleted items, paragraphs, with inline
/// code, bold, and links.
struct MarkdownPreview: View {
    var markdown: String

    var body: some View {
        let blocks = MarkdownBlock.parse(markdown)
        VStack(alignment: .leading, spacing: 6) {
            if blocks.isEmpty {
                Text("No text is added.").foregroundStyle(.secondary).italic()
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    Self.inline(text).font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                case let .listItem(marker, text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).monospacedDigit().foregroundStyle(.secondary)
                        Self.inline(text)
                    }
                case let .paragraph(text):
                    Self.inline(text)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        // Text's own code styling drops some spans; set the monospaced font on each one.
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(.callout, design: .monospaced)
        }
        return Text(attributed)
    }
}

/// The review's one title (`HS2-025XNF`, §7.2): a full-width bordered field, so it reads as
/// editable, with a hint that it is the new ticket's title (or heads the existing ticket's note).
struct ReviewTitleField: View {
    @ObservedObject var model: ReviewSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Title")
            TextField("Title", text: $model.title, prompt: Text("What was reviewed"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel("Title")
                .accessibilityIdentifier("session-title")
            Text(model.session.destination == .newTicket ? "Also the new ticket's title." : "Heads the note added to the ticket.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
