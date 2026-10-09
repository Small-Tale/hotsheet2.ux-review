import AppKit
import SwiftUI
import UXReviewKit

/// Right-hand panel, a navigation stack (`HS2-4R84WH`): every annotation on the current capture
/// at the root; clicking one (or selecting it on the canvas) pushes its editor, whose Back button
/// returns to the list and deselects. The stack follows the editor's selection
/// (`InspectorNavigation`). Spec: docs/06-annotation-editor.md §6.5.1.
struct InspectorView: View {
    @ObservedObject var model: EditorModel

    private var path: Binding<[String]> {
        Binding(
            get: { InspectorNavigation.path(selection: model.editor.selectedAnnotation?.id) },
            set: { path in
                guard let change = InspectorNavigation.selection(afterNavigatingTo: path, current: model.editor.selection)
                else { return }
                model.mutate { $0.select(change) }
            }
        )
    }

    var body: some View {
        NavigationStack(path: path) {
            AnnotationList(model: model)
                .navigationDestination(for: String.self) { id in
                    AnnotationPage(model: model, id: id)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// One annotation's editor, pushed over the list: a Back button (⌘[) to the list, then the
/// annotation's intents, shape options, time, and note.
struct AnnotationPage: View {
    @ObservedObject var model: EditorModel
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { model.mutate { $0.select(nil) } } label: {
                    Label("Annotations", systemImage: "chevron.backward")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to the annotation list (⌘[)")
                .accessibilityLabel("Back to annotations")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            Divider()
            if let annotation = model.editor.annotation(id) {
                ScrollView {
                    AnnotationDetail(model: model, annotation: annotation)
                        .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationBarBackButtonHidden(true)
    }
}

struct AnnotationDetail: View {
    @ObservedObject var model: EditorModel
    let annotation: Annotation
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                NumberBadge(number: model.editor.number(of: annotation.id) ?? 0, intent: annotation.primaryIntent)
                Text(annotation.shape.label).font(.headline)
                Spacer()
                Button { model.mutate { _ = $0.duplicateSelection() } } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate")
                Button { model.mutate { _ = $0.deleteSelection() } } label: { Image(systemName: "trash") }
                    .help("Delete (⌫)")
            }
            .buttonStyle(.borderless)

            Text("Intent").font(.caption).foregroundStyle(.secondary)
            IntentChips(annotation: annotation) { intent, click in
                model.mutate { _ = $0.clickIntent(intent, click, for: annotation.id) }
            }

            if case let .freehand(_, closed) = annotation.shape {
                Toggle("Closed outline", isOn: Binding(
                    get: { closed },
                    set: { value in model.mutate { _ = $0.setClosed(value, for: annotation.id) } }
                ))
                .toggleStyle(.checkbox)
            }

            if case let .arrow(_, heads) = annotation.shape {
                ArrowHeadsEditor(heads: heads) { heads in
                    model.mutate { _ = $0.setArrowHeads(heads, for: annotation.id) }
                }
            }

            if model.editor.media(annotation.mediaId)?.kind == .video {
                TimeRangeEditor(model: model, annotation: annotation)
            }

            Text("Note").font(.caption).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                // Reads the model, not the captured `annotation`: right after a keystroke that copy
                // is one character behind, and handing it back makes the text view replace its
                // text and put the insertion point at the end (`HS2-XCJPTX`).
                TextEditor(text: Binding(
                    get: { [id = annotation.id] in model.editor.annotation(id)?.note ?? "" },
                    set: { text in model.mutate { _ = $0.setNote(text, for: annotation.id) } }
                ))
                .font(.body)
                .focused($noteFocused)
                .scrollContentBackground(.hidden)
                .padding(4)
                .help(markdownHelp)
                if annotation.note.isEmpty {
                    Text("What should change here?")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 90, maxHeight: 160)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
        }
        .onChange(of: model.focusNoteRequest) { focusNote() }
        // A double-click or Return on the canvas can ask for the note before this page is pushed.
        .onAppear { if model.focusNoteRequest != model.noteFocusHandled { focusNote() } }
    }

    private func focusNote() {
        model.noteFocusHandled = model.focusNoteRequest
        DispatchQueue.main.async { noteFocused = true }
    }
}

/// An arrow's Start and End heads (`HS2-HQV9R8`, docs/06 §6.3): none, open, closed, flat, or an
/// open or closed circle at each end.
struct ArrowHeadsEditor: View {
    let heads: ArrowHeads
    let set: (ArrowHeads) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Arrow heads").font(.caption).foregroundStyle(.secondary)
            // Two columns sharing the inspector's 300 pt, so neither menu pushes it wider.
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Start")
                    Text("End")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                GridRow {
                    picker("Start", heads.start) { set(ArrowHeads(start: $0, end: heads.end)) }
                    picker("End", heads.end) { set(ArrowHeads(start: heads.start, end: $0)) }
                }
            }
        }
    }

    private func picker(_ title: String, _ value: ArrowHead, _ choose: @escaping (ArrowHead) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: choose)) {
            ForEach(ArrowHead.allCases, id: \.self) { head in
                Text(head.displayName).tag(head)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(title) head")
    }
}

/// When an annotation on a video shows: the whole clip, or a range whose ends are typed, set from
/// the playhead, or dragged on the timeline (docs/06 §6.10).
struct TimeRangeEditor: View {
    @ObservedObject var model: EditorModel
    let annotation: Annotation

    var body: some View {
        let now = model.editor.currentTimeMs
        let duration = model.editor.media(annotation.mediaId)?.durationMs ?? 0
        VStack(alignment: .leading, spacing: 6) {
            Text("Time").font(.caption).foregroundStyle(.secondary)
            Toggle("Whole clip", isOn: Binding(
                get: { annotation.timeRange == nil },
                set: { whole in
                    model.mutate { _ = $0.setTimeRange(whole ? nil : TimeRange(startMs: now, endMs: duration), for: annotation.id) }
                }
            ))
            .toggleStyle(.checkbox)
            if let range = annotation.timeRange {
                endpoint("From", .rangeStart, range.startMs)
                endpoint("To", .rangeEnd, range.endMs)
            }
        }
    }

    /// Sets one end (typed, or the playhead) and shows the frame there. Moving From past To, or To
    /// before From, drags the other end along.
    private func set(_ handle: TimelineHandle, to millis: Int) {
        model.mutate { editor in
            guard editor.setRangeEnd(handle, toMs: millis, for: annotation.id),
                  let range = editor.annotation(annotation.id)?.timeRange else { return }
            editor.setCurrentTime(handle == .rangeStart ? range.startMs : range.endMs)
        }
    }

    private func endpoint(_ label: String, _ handle: TimelineHandle, _ millis: Int) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 36, alignment: .leading)
            TimeField(label: label, millis: millis) { set(handle, to: $0) }
                .help("Type a time, for example 1.5 or 0:01.50")
            Button { model.mutate { $0.movePlayhead(to: millis) } } label: { Image(systemName: "scope") }
                .buttonStyle(.borderless)
                .help("Move the playhead here")
                .accessibilityLabel("Show \(label.lowercased()) \(TimeFormat.clock(millis))")
            Spacer(minLength: 4)
            Button("Set to Playhead") { set(handle, to: model.editor.currentTimeMs) }
                .controlSize(.small)
                .help("\(label) \(TimeFormat.clock(model.editor.currentTimeMs))")
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label) \(TimeFormat.clock(millis))")
    }
}

/// One chip per intent. Effective intents are on; when the list is empty the shape's default
/// shows as on with a "default" hint. A click selects just that intent; ⌘- or ⇧-click toggles it
/// into a multiple selection (`IntentToggle.Click`, docs/06 §6.5). VoiceOver gets the toggle as a
/// named action, since it can't hold a modifier.
struct IntentChips: View {
    let annotation: Annotation
    let click: (Intent, IntentToggle.Click) -> Void

    var body: some View {
        let effective = Set(annotation.effectiveIntents)
        FlowLayout(spacing: 6) {
            ForEach(Intent.allCases, id: \.self) { intent in
                let isOn = effective.contains(intent)
                Button { click(intent, Self.click(NSEvent.modifierFlags)) } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color(cgColor: IntentPalette.color(intent))).frame(width: 8, height: 8)
                        Text(intent.rawValue)
                        if isOn, annotation.intents.isEmpty {
                            Text("default").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(isOn ? Color(cgColor: IntentPalette.color(intent, alpha: 0.22)) : Color.primary.opacity(0.05))
                    )
                    .overlay(Capsule().stroke(isOn ? Color(cgColor: IntentPalette.color(intent)) : Color.primary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help("\(intent.help). ⌘-click to add or remove it alongside other intents.")
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityAction(named: isOn ? "Remove from intents" : "Add to intents") { click(intent, .toggle) }
            }
        }
    }

    /// ⌘ or ⇧ held: toggle into a multiple selection; otherwise select just this intent.
    static func click(_ flags: NSEvent.ModifierFlags) -> IntentToggle.Click {
        IntentToggle.Click(command: flags.contains(.command), shift: flags.contains(.shift))
    }
}

struct AnnotationList: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let mediaId = model.editor.currentMediaId ?? ""
        let annotations = model.editor.annotations(on: mediaId)
        VStack(alignment: .leading, spacing: 0) {
            if let media = model.editor.currentMedia {
                CaptureNoteField(model: model, mediaId: media.id)
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                    .id(media.id)
            }
            Text(annotations.isEmpty ? "Annotations" : "Annotations (\(annotations.count))")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            if annotations.isEmpty {
                EmptyHint(hasMedia: model.editor.currentMedia != nil)
                    .padding(12)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(annotations, id: \.id) { annotation in
                            NavigationLink(value: annotation.id) {
                                AnnotationRow(
                                    number: model.editor.number(of: annotation.id) ?? 0,
                                    annotation: annotation,
                                    selected: annotation.id == model.editor.selection,
                                    onVideo: model.editor.currentDurationMs != nil,
                                    showing: annotation.isVisible(atMs: model.editor.currentTimeMs),
                                    outside: model.editor.outsideReason(annotation)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows its intents and note")
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AnnotationRow: View {
    let number: Int
    let annotation: Annotation
    let selected: Bool
    var onVideo = false
    /// False when the playhead is outside the annotation's range (it is dimmed).
    var showing = true
    /// "crop" or "trim" when the annotation lies outside it: hidden, and left out when submitting
    /// (HS2-71SSJG, docs/06 §6.6).
    var outside: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            NumberBadge(number: number, intent: annotation.primaryIntent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(annotation.shape.label) · \(annotation.effectiveIntents.map(\.rawValue).joined(separator: ", "))")
                    .font(.callout.weight(.medium))
                if let outside {
                    Label("Outside the \(outside) · left out when submitting", systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if onVideo {
                    Label(TimeFormat.range(annotation.timeRange), systemImage: "clock")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(annotation.note.isEmpty ? "No note" : annotation.note)
                    .font(.callout)
                    .foregroundStyle(annotation.note.isEmpty ? .tertiary : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .opacity(showing && outside == nil ? 1 : 0.55)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
    }
}

struct NumberBadge: View {
    let number: Int
    let intent: Intent

    var body: some View {
        Text("\(number)")
            .font(.caption.weight(.bold))
            .foregroundStyle(IntentPalette.usesDarkText(intent) ? Color.black : Color.white)
            .frame(minWidth: 20, minHeight: 20)
            .background(Circle().fill(Color(cgColor: IntentPalette.color(intent))))
    }
}

struct EmptyHint: View {
    var hasMedia = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hasMedia ? "Pick a tool and drag on the image." : "Add an image or movie to start annotating.").font(.callout)
            Group {
                Text("R rectangle · F freehand · A arrow")
                Text("I insertion · S strike · C crop · V select")
                Text("⌫ delete · arrows nudge · Tab next · ⌘Z undo")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

extension Intent {
    var help: String {
        switch self {
        case .comment: "General observation or feedback"
        case .bug: "Something is broken or wrong"
        case .change: "Change the marked element (style, copy, behavior)"
        case .insert: "Insert something here"
        case .remove: "Remove the marked element"
        case .move: "Move the marked element"
        case .question: "Open question for the product owner or developer"
        }
    }
}

/// Wraps chips onto as many rows as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        )
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
