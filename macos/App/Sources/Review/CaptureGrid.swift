import AppKit
import SwiftUI
import UXReviewKit

/// The Submit Review window's captures (`HS2-55N4BN`, docs/07 §7.2): a grid of the media as it will
/// be filed, nothing to manipulate. Captures are annotated and removed in the editor. Each tile is
/// the thumbnail (a play badge on videos), with its annotation count, and an orange badge when it
/// has a problem; its details (file, size as filed, length, app, note) are its tooltip and VoiceOver
/// label. Problems, and annotations a crop or trim leaves out, are listed under the grid, since
/// they matter before filing.
struct CaptureGrid: View {
    @ObservedObject var model: ReviewSessionModel
    /// The first issue about a capture (missing file, annotation problems), from the window.
    let problem: (MediaItem) -> String?

    static let tileSize = CGSize(width: 132, height: 84)

    var body: some View {
        let media = model.session.bundle.media
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileSize.width), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(media, id: \.id) { item in
                    tile(item)
                }
            }
            ForEach(notes(media), id: \.self) { line in
                Label(line.text, systemImage: line.problem ? "exclamationmark.triangle.fill" : "eye.slash")
                    .font(.caption)
                    .foregroundStyle(line.problem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func tile(_ item: MediaItem) -> some View {
        let filed = model.preview.media[item.id]
        let annotations = filed?.annotationCount ?? 0
        let problem = problem(item)
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85))
            if let thumbnail = model.thumbnails[item.id] {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.kind == .video ? "film" : "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.tileSize.width, height: Self.tileSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
            problem == nil ? Color.primary.opacity(0.15) : .orange,
            lineWidth: problem == nil ? 1 : 2
        ))
        .overlay(alignment: .bottomLeading) {
            if item.kind == .video {
                badge(Image(systemName: "play.fill").font(.system(size: 9)), fill: .black.opacity(0.6))
            }
        }
        .overlay(alignment: .topTrailing) {
            if annotations > 0 {
                badge(Text("\(annotations)").font(.caption2.weight(.semibold)), fill: .accentColor)
            }
        }
        .overlay(alignment: .topLeading) {
            if problem != nil {
                badge(Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)), fill: .orange)
            }
        }
        .help(details(item, filed: filed))
        .accessibilityElement()
        .accessibilityLabel(details(item, filed: filed) + (problem.map { ". \($0)" } ?? ""))
    }

    private func badge(_ content: some View, fill: Color) -> some View {
        content
            .foregroundStyle(.white)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 2)
            .background(Capsule(style: .circular).fill(fill))
            .padding(4)
    }

    /// "capture-1.png · 1389×868 scaled for Claude · 0:02.00 trimmed · 2 annotations · Acme Mail",
    /// then the capture's note on its own line.
    func details(_ item: MediaItem, filed: SubmissionPreview.Filed?) -> String {
        var parts = [item.filename, filed?.sizeText ?? "\(item.pixelWidth)×\(item.pixelHeight)"]
        if let duration = filed?.durationMs ?? item.durationMs {
            parts.append(TimeFormat.clock(duration) + (filed?.trim == nil ? "" : " trimmed"))
        }
        let annotations = filed?.annotationCount ?? 0
        parts.append(annotations == 0 ? "no annotations" : "\(annotations) annotation\(annotations == 1 ? "" : "s")")
        if let app = item.context?.appName { parts.append(app) }
        let note = SubmissionPreview.notePreview(item.note).map { "\nNote: \($0)" } ?? ""
        return parts.joined(separator: " · ") + note
    }

    struct Line: Hashable {
        var text: String
        var problem: Bool
    }

    /// Under the grid: each capture's problem, then what a crop or trim leaves out, by file name.
    private func notes(_ media: [MediaItem]) -> [Line] {
        media.compactMap { item in problem(item).map { Line(text: "\(item.filename): \($0)", problem: true) } }
            + media.compactMap { item in
                model.preview.media[item.id]?.leftOutNote.map { Line(text: "\(item.filename): \($0)", problem: false) }
            }
    }
}
