import AppKit
import SwiftUI
import UXReviewKit

/// The annotation editor window's content: tool bar on top; media strip, canvas, and inspector
/// below. Spec: docs/06-annotation-editor.md §6.1.
struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(model: model)
            Divider()
            HStack(spacing: 0) {
                // Shown with one capture too, so it can be removed (HS2-SSM1E7).
                if !model.editor.bundle.media.isEmpty {
                    MediaStrip(model: model)
                        .frame(width: 112)
                    Divider()
                }
                VStack(spacing: 0) {
                    AnnotationCanvas(model: model)
                        .frame(minWidth: 420, minHeight: 300)
                    if model.editor.currentDurationMs != nil {
                        Divider()
                        TimelineBar(model: model)
                    }
                }
                Divider()
                InspectorView(model: model)
                    .frame(width: 300)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

struct EditorToolbar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases, id: \.self) { tool in
                    ToolButton(tool: tool, selected: model.editor.tool == tool) {
                        model.mutate { $0.setTool(tool) }
                    }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            if let item = model.editor.currentMedia, model.editor.canRestoreOriginal {
                Button("Restore Original") { model.mutate { _ = $0.restoreOriginal() } }
                    .help(
                        item.kind == .video
                            ? "Remove this video's crop and trim, including ones from an earlier session; hidden annotations come back"
                            : "Remove this capture's crop, including one from an earlier session; hidden annotations come back"
                    )
            }
            Spacer(minLength: 8)
            StatusLine(model: model)
            ZoomControl(model: model)
            if let submit = model.submitReview {
                Button("Submit Review…", action: submit)
                    .buttonStyle(.bordered)
                    .help("Save and open the Submit Review window for this review (⌘↩)")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// − [percent ▾] +, where the menu offers Fit and Actual Pixels. Mirrors ⌘-, ⌘0/⌘1, ⌘+.
struct ZoomControl: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom Out (⌘-)")
            Menu {
                Button("Zoom to Fit (⌘0)") { model.zoomToFit() }
                Button("Actual Pixels (⌘1)") { model.zoomToActualPixels() }
                Divider()
                Button("Zoom In (⌘+)") { model.zoomIn() }
                Button("Zoom Out (⌘-)") { model.zoomOut() }
            } label: {
                Text(model.zoomPercent.map { "\($0) %" } ?? "–")
                    .monospacedDigit()
                    .frame(minWidth: 52)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(model.viewport.isFit ? "Fitted to the window. Pinch, ⌘-scroll, or ⌘+ to zoom" : "Scroll or space-drag to pan")
            .accessibilityLabel("Zoom")
            .accessibilityValue(model.zoomPercent.map { "\($0) percent" } ?? "")
            Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom In (⌘+)")
        }
        .disabled(model.editor.currentMedia == nil)
    }
}

struct ToolButton: View {
    let tool: EditorTool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.label) (\(String(tool.shortcut).uppercased()))")
        .accessibilityLabel(tool.label)
    }
}

/// Status message, save state, and errors, right-aligned in the tool bar.
struct StatusLine: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 6) {
            if let error = model.saveError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(1).truncationMode(.middle)
            } else if let message = model.editor.message {
                Text(message).lineLimit(1).truncationMode(.tail)
            } else {
                Text(model.editor.isDirty ? "Editing…" : "Saved to draft")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

/// Thumbnails of every capture in the review, with the number of annotations on each. Click
/// shows one; ⌘-click and ⇧-click select several (docs/06 §6.7.2), and the canvas shows the
/// last one clicked.
struct MediaStrip: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let selection = Set(model.editor.selectedMediaIds)
        ScrollView {
            VStack(spacing: 4) {
                ForEach(model.editor.bundle.media, id: \.id) { item in
                    let shown = item.id == model.editor.currentMediaId
                    let selected = selection.contains(item.id)
                    Button { model.mutate { $0.clickMedia(item.id, Self.click(NSEvent.modifierFlags)) } } label: {
                        VStack(spacing: 4) {
                            thumbnail(item)
                                .frame(width: 88, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(
                                            selected ? Color.accentColor : Color.primary.opacity(0.15),
                                            lineWidth: shown ? 2.5 : selected ? 1.5 : 1
                                        )
                                )
                                .overlay(alignment: .topTrailing) { countBadge(item) }
                            Text(item.filename).font(.caption2).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                        }
                        .padding(3)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(selected && selection.count > 1 ? 0.16 : 0))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .overlay(alignment: .topLeading) {
                        if shown, let confirm = model.confirmRemoval {
                            let targets = removalTargets(item)
                            Button { confirm(targets) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.black.opacity(0.6))
                                    .font(.system(size: 15))
                            }
                            .buttonStyle(.plain)
                            .offset(x: -2, y: -2)
                            .help(removalHelp(targets))
                            .accessibilityLabel(removalHelp(targets))
                        }
                    }
                    .contextMenu {
                        if let confirm = model.confirmRemoval {
                            let targets = removalTargets(item)
                            Button("\(CaptureRemovalPrompt.title(count: targets.count)) from Review…") { confirm(targets) }
                        }
                    }
                }
            }
            .padding(7)
        }
    }

    /// ⌘-click toggles, ⇧-click extends; ⌘ wins when both are held.
    static func click(_ flags: NSEvent.ModifierFlags) -> MediaSelection.Click {
        flags.contains(.command) ? .toggle : flags.contains(.shift) ? .extend : .plain
    }

    /// The selection when `item` is in it, else `item` alone.
    private func removalTargets(_ item: MediaItem) -> [MediaItem] {
        model.editor.mediaToRemove(from: item.id).compactMap(model.editor.media)
    }

    private func removalHelp(_ targets: [MediaItem]) -> String {
        targets.count == 1 ? "Remove \(targets[0].filename) from the review" : "Remove \(targets.count) selected captures from the review"
    }

    @ViewBuilder private func thumbnail(_ item: MediaItem) -> some View {
        if let image = model.image(item.id) {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                .overlay(alignment: .bottomLeading) {
                    if item.kind == .video {
                        Image(systemName: "video.fill").font(.caption2).padding(3).foregroundStyle(.white).shadow(radius: 2)
                    }
                }
        } else {
            Rectangle().fill(Color.primary.opacity(0.1))
        }
    }

    @ViewBuilder private func countBadge(_ item: MediaItem) -> some View {
        let count = model.editor.annotations(on: item.id).count
        if count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(Color.accentColor))
                .offset(x: 5, y: -5)
        }
    }
}

extension EditorTool {
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rect: "rectangle"
        case .freehand: "scribble"
        case .arrow: "arrow.up.right"
        case .insertion: "control"
        case .strike: "xmark.rectangle"
        case .crop: "crop"
        }
    }
}

extension UXReviewKit.Shape {
    var label: String { displayName }
}
