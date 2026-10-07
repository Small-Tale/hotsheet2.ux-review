import SwiftUI
import UXReviewKit

/// The Draft Reviews window: every draft review on disk, most recently edited first, with
/// Open Session, Annotate, Show in Finder, and Discard. Spec: docs/07-review-session.md §7.9.
struct DraftsView: View {
    struct Actions {
        var openSession: (DraftSummary) -> Void = { _ in }
        var annotate: (DraftSummary) -> Void = { _ in }
        var reveal: (DraftSummary) -> Void = { _ in }
        var discard: (DraftSummary) -> Void = { _ in }
        var showFolder: () -> Void = {}
    }

    static let minimumSize = CGSize(width: 560, height: 320)

    @ObservedObject var model: DraftsModel
    var actions = Actions()

    var body: some View {
        VStack(spacing: 0) {
            if model.drafts.isEmpty, model.problem == nil {
                emptyState
            } else {
                List {
                    ForEach(model.drafts) { draft in
                        DraftRow(draft: draft, actions: actions)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            footer
        }
    }

    /// Drawn by hand: `ContentUnavailableView` renders blank offscreen (--render-ui-previews).
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Draft Reviews").font(.title3.weight(.semibold))
            Text(
                "Your first capture starts a draft review. Reviews you set aside with New Review "
                    + "stay here until you submit or discard them."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 380)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                let count = model.drafts.count
                Text("\(count) draft\(count == 1 ? "" : "s") · Discarded drafts go to the Trash")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Show Drafts Folder", action: actions.showFolder)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct DraftRow: View {
    let draft: DraftSummary
    let actions: DraftsView.Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: draft.isReadable ? "doc.text.image" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(draft.isReadable ? Color.secondary : Color.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(draft.title.isEmpty ? "Untitled review" : draft.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if draft.isCurrent {
                        Text("Current")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .foregroundStyle(Color.accentColor)
                            .fixedSize()
                    }
                }
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let issue = draft.issue {
                    Text("Can't be opened: \(issue)").font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else if let slug = draft.pendingTicket {
                    Text("\(slug) was created; its media isn't attached yet").font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(draft.title)
    }

    private var details: String {
        var parts: [String] = []
        if draft.isReadable {
            parts.append("\(draft.captureCount) capture\(draft.captureCount == 1 ? "" : "s")")
            parts.append("\(draft.annotationCount) annotation\(draft.annotationCount == 1 ? "" : "s")")
        }
        parts.append("edited \(draft.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
        return parts.joined(separator: " · ")
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button("Open Session") { actions.openSession(draft) }
                .disabled(!draft.isReadable)
                .help("Title, captures, and Submit to Hot Sheet")
            Button("Annotate") { actions.annotate(draft) }
                .disabled(!draft.isReadable || draft.captureCount == 0)
            Button { actions.reveal(draft) } label: { Image(systemName: "folder") }
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            Button { actions.discard(draft) } label: { Image(systemName: "trash") }
                .help("Discard…")
                .accessibilityLabel("Discard")
        }
        .controlSize(.small)
        .fixedSize()
    }
}
