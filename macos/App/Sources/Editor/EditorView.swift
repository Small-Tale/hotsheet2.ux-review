import AppKit
import SwiftUI
import UXReviewKit

/// The annotation editor window's content under its native toolbar (`EditorToolbar`): media
/// strip, canvas, and inspector. Spec: docs/06-annotation-editor.md §6.1.
struct EditorView: View {
    @ObservedObject var model: EditorModel
    /// The media strip's width as last dragged, kept across windows and launches (`HS2-AH6HW4`).
    @AppStorage("editorMediaStripWidth", store: AppSettings.defaults) private var savedStripWidth = Double(MediaStripWidth.standard)
    /// Previews fix the width instead of reading the saved one.
    var stripWidthOverride: CGFloat?
    /// Previews draw the shown thumbnail as if the pointer were over it (its ✕ revealed).
    var stripHoverOverride = false
    /// The width while the divider is being dragged; saved when the drag ends.
    @State private var draggedStripWidth: CGFloat?
    @State private var dragStartWidth: CGFloat?

    private var stripWidth: CGFloat {
        draggedStripWidth ?? stripWidthOverride ?? MediaStripWidth.clamped(CGFloat(savedStripWidth))
    }

    /// The canvas's minimum width and the inspector's width (`HS2-RZVDEQ`).
    static let canvasMinWidth: CGFloat = 420
    static let inspectorWidth: CGFloat = 300

    var body: some View {
        GeometryReader { window in
            // The strip gives way in a narrow window, so the inspector is never pushed past the
            // window's edge (`HS2-RZVDEQ`). Two 1-point dividers sit between the columns.
            let strip = MediaStripWidth.fitted(stripWidth, available: window.size.width - Self.canvasMinWidth - Self.inspectorWidth - 2)
            columns(stripWidth: strip)
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private func columns(stripWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Shown with one capture too, so it can be removed (HS2-SSM1E7).
                if !model.editor.bundle.media.isEmpty {
                    MediaStrip(model: model, width: stripWidth, hoverOverride: stripHoverOverride)
                        .frame(width: stripWidth)
                    StripDivider(width: stripWidth, drag: { dragStrip($0, from: stripWidth) }, end: endStripDrag, set: setStripWidth)
                }
                VStack(spacing: 0) {
                    AnnotationCanvas(model: model)
                        .frame(minWidth: Self.canvasMinWidth, minHeight: 300)
                        .overlay(alignment: .top) { EditorToastOverlay(model: model) }
                    if model.editor.currentDurationMs != nil {
                        Divider()
                        TimelineBar(model: model)
                    }
                }
                Divider()
                InspectorView(model: model)
                    .frame(width: Self.inspectorWidth)
            }
        }
    }

    /// A divider drag, measured from the width shown when it began (narrower than the saved one
    /// in a narrow window).
    private func dragStrip(_ translation: CGFloat, from shown: CGFloat) {
        let start = dragStartWidth ?? shown
        dragStartWidth = start
        draggedStripWidth = MediaStripWidth.dragged(from: start, by: translation)
    }

    private func endStripDrag() {
        if let draggedStripWidth { savedStripWidth = Double(draggedStripWidth) }
        draggedStripWidth = nil
        dragStartWidth = nil
    }

    private func setStripWidth(_ width: CGFloat) {
        savedStripWidth = Double(MediaStripWidth.clamped(width))
    }
}

/// The line between the media strip and the canvas, which drags to resize the strip
/// (`HS2-AH6HW4`). Double-click returns it to the standard width; VoiceOver adjusts it in steps.
struct StripDivider: View {
    let width: CGFloat
    let drag: (CGFloat) -> Void
    let end: () -> Void
    let set: (CGFloat) -> Void

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.columnResize.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag($0.translation.width) }
                            .onEnded { _ in end() }
                    )
                    .onTapGesture(count: 2) { set(MediaStripWidth.standard) }
            }
            .accessibilityElement()
            .accessibilityLabel("Capture sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set(width + 16)
                case .decrement: set(width - 16)
                @unknown default: break
                }
            }
            .help("Drag to resize the capture sidebar; double-click for the standard width")
    }
}

/// The editor's message or a save error as a toast at the top of the canvas (`HS2-KJCJWX`): a
/// message fades after a few seconds, an error stays until saving works again.
struct EditorToastOverlay: View {
    @ObservedObject var model: EditorModel
    @State private var presenter = ToastPresenter()

    var body: some View {
        let current = EditorToast.current(message: model.editor.message, saveError: model.saveError)
        ZStack {
            if let toast = presenter.visible(current) {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: presenter.visible(current))
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .task(id: current) {
            presenter.changed()
            guard let current, let duration = current.duration else { return }
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { presenter.expire(current) }
        }
    }
}

struct ToastView: View {
    let toast: EditorToast

    var body: some View {
        HStack(spacing: 8) {
            if toast.kind == .error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(toast.text)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // Opaque, not glass: it sits on the canvas and must read on any capture.
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Thumbnails of every capture in the review, with the number of annotations on each. Click
/// shows one; ⌘-click and ⇧-click select several (docs/06 §6.7.2), and the canvas shows the
/// last one clicked.
struct MediaStrip: View {
    @ObservedObject var model: EditorModel
    var width = MediaStripWidth.standard
    var hoverOverride = false
    /// The thumbnail under the pointer, and the one with keyboard focus (Full Keyboard Access).
    @State private var hovered: String?
    @FocusState private var focused: String?

    var body: some View {
        let selection = Set(model.editor.selectedMediaIds)
        ScrollView {
            VStack(spacing: 4) {
                ForEach(model.editor.bundle.media, id: \.id) { item in
                    let shown = item.id == model.editor.currentMediaId
                    let selected = selection.contains(item.id)
                    Button { model.mutate { $0.clickMedia(item.id, Self.click(NSEvent.modifierFlags)) } } label: {
                        VStack(spacing: 4) {
                            let size = MediaStripWidth.thumbnail(for: width)
                            thumbnail(item)
                                .frame(width: size.width, height: size.height)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                // Clipping hides the filled image's overflow but doesn't stop it
                                // taking clicks: a portrait capture's overflow covered its
                                // neighbors, so their clicks went nowhere (HS2-QXJZJ9).
                                .contentShape(RoundedRectangle(cornerRadius: 4))
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
                        // The whole cell takes the click, not just the thumbnail and the
                        // filename's glyphs (a plain button hit-tests only what it draws).
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .focused($focused, equals: item.id)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    // VoiceOver reaches removal while the ✕ is hidden (`HS2-WTPT8X`).
                    .accessibilityAction(named: "\(CaptureRemovalPrompt.title(count: removalTargets(item).count)) from Review") {
                        if let confirm = model.confirmRemoval { confirm(removalTargets(item)) }
                    }
                    // The ✕ shows on the shown thumbnail only while the pointer is over it or it
                    // has keyboard focus, like Finder's and Photos' close buttons (`HS2-WTPT8X`);
                    // the context menu and Edit › Remove Capture from Review… are always there.
                    .overlay(alignment: .topLeading) {
                        if shown, hoverOverride || hovered == item.id || focused == item.id, let confirm = model.confirmRemoval {
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
                    // After the ✕'s overlay, so moving onto the ✕ still counts as over the cell.
                    .onHover { inside in
                        if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
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
    /// The tool's tooltip: its name and shortcut, such as "Rectangle (R)".
    var toolTip: String { "\(label) (\(String(shortcut).uppercased()))" }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rect: "rectangle"
        case .freehand: "scribble"
        case .arrow: "arrow.up.right"
        case .insertion: "text.insert"
        case .strike: "xmark.rectangle"
        case .crop: "crop"
        }
    }
}

extension UXReviewKit.Shape {
    var label: String { displayName }
}
