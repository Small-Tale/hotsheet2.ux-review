import SwiftUI
import UXReviewKit

/// The review session window: captures, title and summary, the Hot Sheet project, what still
/// blocks submitting, and the submission's progress and result. Spec: docs/07-review-session.md §7.2.
struct ReviewSessionView: View {
    @ObservedObject var model: ReviewSessionModel
    var annotate: (String?) -> Void = { _ in }
    var done: () -> Void = {}
    /// Discard Review…: asks, then moves the draft to the Trash (docs/07 §7.9).
    var discard: () -> Void = {}

    @State private var pendingRemoval: MediaItem?

    var body: some View {
        if case let .submitted(review) = model.session.phase {
            SubmittedView(review: review, copySlug: model.copySlug, showTicketFile: model.showTicketFile, done: done)
        } else {
            VStack(spacing: 0) {
                form
                Divider()
                footer
            }
            .confirmationDialog(
                "Remove \(pendingRemoval?.filename ?? "") from this review?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                presenting: pendingRemoval
            ) { item in
                Button("Remove Capture", role: .destructive) { model.remove(mediaId: item.id) }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                let count = model.session.annotationCount(item.id)
                Text(
                    count == 0 ? "The file is deleted from the draft." :
                        "The file and its \(count) annotation\(count == 1 ? "" : "s") are deleted from the draft."
                )
            }
        }
    }

    private var editable: Bool { model.session.isEditable }

    private var form: some View {
        Form {
            // Rare whole-review problems (format, duplicate ids); the common ones show inline.
            let general = model.session.issues.filter(isGeneralIssue)
            if !general.isEmpty {
                Section {
                    ForEach(Array(general.enumerated()), id: \.offset) { _, issue in
                        IssueLabel(text: issue.message(in: model.session.bundle))
                    }
                } header: {
                    Text("Before submitting")
                }
            }

            Section {
                TextField("Title", text: $model.title, prompt: Text("What was reviewed"))
                    .accessibilityIdentifier("session-title")
                if model.session.issues.contains(.blankTitle) {
                    IssueLabel(text: SessionIssue.blankTitle.message(in: model.session.bundle))
                        .font(.caption)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Summary")
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.summary)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 72, maxHeight: 120)
                            // TextEditor doesn't dim itself when disabled.
                            .foregroundStyle(editable ? .primary : .secondary)
                            .accessibilityIdentifier("session-summary")
                        if model.summary.isEmpty {
                            Text("Overall notes for the whole review (Markdown, optional)")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                }
            } header: {
                Text("Review")
            }
            .disabled(!editable)

            Section {
                if model.session.bundle.media.isEmpty {
                    Text("No captures yet. Take a screenshot or record a video from the menu bar.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.session.bundle.media, id: \.id) { item in
                    CaptureRow(
                        item: item,
                        number: (model.session.bundle.media.firstIndex(of: item) ?? 0) + 1,
                        filed: model.preview.media[item.id],
                        thumbnail: model.thumbnails[item.id],
                        problem: problem(for: item),
                        editable: editable,
                        annotate: { annotate(item.id) },
                        remove: { pendingRemoval = item }
                    )
                }
            } header: {
                HStack {
                    Text("Captures (\(model.session.bundle.media.count))")
                    Spacer()
                    Button("Annotate…") { annotate(nil) }
                        .controlSize(.small)
                        .disabled(!editable || model.session.bundle.media.isEmpty)
                }
            }

            Section {
                ProjectRow(model: model)
            } header: {
                Text("Hot Sheet project")
            }
            .disabled(!editable)

            Section {
                ReviewDestinationRows(model: model)
            } header: {
                Text("Ticket")
            }
            .disabled(!editable)
        }
        .formStyle(.grouped)
    }

    /// Issues not shown next to a field, a capture, the project, or the ticket.
    private func isGeneralIssue(_ issue: SessionIssue) -> Bool {
        switch issue {
        case .noCaptures, .blankTitle, .hotSheet, .missingFile, .ticket: false
        case .bundle: issue.mediaId(in: model.session.bundle) == nil
        }
    }

    /// The first issue about this capture (missing file, annotation problems).
    private func problem(for item: MediaItem) -> String? {
        let bundle = model.session.bundle
        let issues = model.session.issues.filter { $0.mediaId(in: bundle) == item.id }
        guard let first = issues.first else { return nil }
        let text = first.message(in: bundle)
        return issues.count > 1 ? "\(text) (+\(issues.count - 1) more)" : text
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Discard Review…", action: discard)
                .disabled(!editable)
                .accessibilityIdentifier("session-discard")
            status
            Spacer(minLength: 8)
            Button(submitTitle) { model.submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.session.canSubmit)
                .accessibilityIdentifier("session-submit")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var submitTitle: String {
        if case .failed = model.session.phase { return "Try Again" }
        if model.session.destination == .existingTicket { return "Add to \(model.session.existingTicket?.slug ?? "Ticket")" }
        return "Submit to Hot Sheet"
    }

    private func progressText(_ step: SubmitStep) -> String {
        let files = "\(model.session.bundle.media.count + 1) files"
        let slug = model.session.existingTicket?.slug
        return switch step {
        case .creatingTicket: "Creating the ticket…"
        case .attachingMedia: slug.map { "Attaching \(files) to \($0)…" } ?? "Attaching \(files)…"
        case .addingNote: "Adding the review note to \(slug ?? "the ticket")…"
        }
    }

    @ViewBuilder private var status: some View {
        switch model.session.phase {
        case let .submitting(step):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progressText(step))
                    .foregroundStyle(.secondary)
            }
        case let .failed(failure):
            VStack(alignment: .leading, spacing: 2) {
                Label("Submitting failed. The review is kept.", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout.weight(.semibold))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                if let slug = failure.createdTicket, failure.partlyAttached {
                    Text("Try Again attaches the remaining files to \(slug) without creating another ticket or attaching any file twice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let slug = failure.createdTicket {
                    Text("Try Again attaches the files to \(slug) without creating another ticket.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let slug = failure.attachedTo, failure.partlyAttached {
                    Text("Try Again attaches the remaining files to \(slug), then adds the review note.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let slug = failure.attachedTo {
                    Text("Try Again adds the review note to \(slug) without attaching the files again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        default:
            if let notice = model.notice {
                IssueLabel(text: notice)
            } else if model.session.canSubmit {
                let media = model.session.bundle.media.count
                let preview = model.preview
                let annotations = preview.annotationCount
                let leftOut = preview.leftOutCount == 0 ? "" : " (\(preview.leftOutCount) left out)"
                Text("\(media) capture\(media == 1 ? "" : "s") · \(annotations) annotation\(annotations == 1 ? "" : "s")\(leftOut)")
                    .foregroundStyle(.secondary)
            } else if model.session.issues.count == 1, let issue = model.session.issues.first {
                Text(issue.message(in: model.session.bundle))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.session.issues.count) things to fix before submitting")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct IssueLabel: View {
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct CaptureRow: View {
    let item: MediaItem
    let number: Int
    /// The capture as it will be filed (nil before the preview knows it: shown as the draft file).
    let filed: SubmissionPreview.Filed?
    let thumbnail: NSImage?
    let problem: String?
    let editable: Bool
    let annotate: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.85))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: item.kind == .video ? "film" : "photo").foregroundStyle(.secondary)
                }
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(.black.opacity(0.6)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(3)
                }
            }
            .frame(width: 72, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename).font(.body.weight(.medium))
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let note = filed?.leftOutNote {
                    Label(note, systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button("Annotate", action: annotate)
                .controlSize(.small)
                .disabled(!editable)
            Button(action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(item.filename) from the review")
            .accessibilityLabel("Remove \(item.filename)")
            .disabled(!editable)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture \(number), \(item.filename)")
    }

    /// Size, length, and annotation count as filed: "cropped" / "trimmed" when an edit applies.
    private var details: String {
        let width = filed?.pixelWidth ?? item.pixelWidth
        let height = filed?.pixelHeight ?? item.pixelHeight
        var parts = ["\(width)×\(height)" + (filed?.crop == nil ? "" : " cropped")]
        if let duration = filed?.durationMs ?? item.durationMs {
            parts.append(TimeFormat.clock(duration) + (filed?.trim == nil ? "" : " trimmed"))
        }
        let annotations = filed?.annotationCount ?? 0
        parts.append(annotations == 0 ? "no annotations" : "\(annotations) annotation\(annotations == 1 ? "" : "s")")
        if let app = item.context?.appName { parts.append(app) }
        return parts.joined(separator: " · ")
    }
}

private struct ProjectRow: View {
    @ObservedObject var model: ReviewSessionModel

    var body: some View {
        let target = model.session.target
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(target.projectDirectory.map { ($0 as NSString).lastPathComponent } ?? "No project chosen")
                    .font(.body.weight(.medium))
                if let problem = target.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let store = target.storePath {
                    Text("Files into \(Self.abbreviated(store))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Menu("Change") {
                let others = model.recentProjects.filter { $0 != target.projectDirectory }
                ForEach(others, id: \.self) { path in
                    Button(Self.abbreviated(path)) { model.useProject(URL(fileURLWithPath: path, isDirectory: true)) }
                }
                if !others.isEmpty { Divider() }
                Button("Choose Folder…") { model.chooseProject() }
            }
            .fixedSize()
        }
    }

    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

private struct SubmittedView: View {
    let review: SubmittedReview
    let copySlug: () -> Void
    let showTicketFile: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(review.addedToExistingTicket ? "Added to \(review.ticket.slug)" : "Filed as \(review.ticket.slug)")
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            Text("“\(review.addedToExistingTicket ? review.ticketTitle ?? review.title : review.title)”")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(summary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button("Copy Slug", action: copySlug)
                Button("Show Ticket File", action: showTicketFile)
                    .disabled(review.ticket.file == nil)
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summary: String {
        let media = "\(review.mediaCount) capture\(review.mediaCount == 1 ? "" : "s")"
        let annotations = "\(review.annotationCount) annotation\(review.annotationCount == 1 ? "" : "s")"
        let store = ((review.storePath as NSString).lastPathComponent)
        var text = review.addedToExistingTicket
            ? "The review “\(review.title)” is a note on this ticket. \(media), \(annotations), and review.json are attached in \(store)."
            : "\(media), \(annotations), and review.json are attached in \(store). "
            + "An AI working the ticket splits it into one ticket per change."
        if !review.draftRemoved { text += "\nThe draft folder could not be deleted; it is no longer the current review." }
        return text
    }
}
