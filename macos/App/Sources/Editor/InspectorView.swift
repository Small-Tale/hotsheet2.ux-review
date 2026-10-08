import SwiftUI
import UXReviewKit

/// Right-hand panel: the selected annotation's intents and Markdown note, then every annotation
/// on the current media. Spec: docs/06-annotation-editor.md §6.5.
struct InspectorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selected = model.editor.selectedAnnotation {
                AnnotationDetail(model: model, annotation: selected)
                    .padding(12)
                Divider()
            }
            AnnotationList(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
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
            IntentChips(annotation: annotation) { intent in
                model.mutate { _ = $0.toggleIntent(intent, for: annotation.id) }
            }

            if case let .freehand(_, closed) = annotation.shape {
                Toggle("Closed outline", isOn: Binding(
                    get: { closed },
                    set: { value in model.mutate { _ = $0.setClosed(value, for: annotation.id) } }
                ))
                .toggleStyle(.checkbox)
            }

            if model.editor.media(annotation.mediaId)?.kind == .video {
                TimeRangeEditor(model: model, annotation: annotation)
            }

            Text("Note (Markdown)").font(.caption).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(
                    get: { annotation.note },
                    set: { text in model.mutate { _ = $0.setNote(text, for: annotation.id) } }
                ))
                .font(.body)
                .focused($noteFocused)
                .scrollContentBackground(.hidden)
                .padding(4)
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
        .onChange(of: model.focusNoteRequest) { noteFocused = true }
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

/// One toggle per intent. Effective intents are on; when the list is empty the shape's default
/// shows as on with a "default" hint.
struct IntentChips: View {
    let annotation: Annotation
    let toggle: (Intent) -> Void

    var body: some View {
        let effective = Set(annotation.effectiveIntents)
        FlowLayout(spacing: 6) {
            ForEach(Intent.allCases, id: \.self) { intent in
                let isOn = effective.contains(intent)
                Button { toggle(intent) } label: {
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
                .help(intent.help)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

struct AnnotationList: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let mediaId = model.editor.currentMediaId ?? ""
        let annotations = model.editor.annotations(on: mediaId)
        VStack(alignment: .leading, spacing: 0) {
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
                            AnnotationRow(
                                number: model.editor.number(of: annotation.id) ?? 0,
                                annotation: annotation,
                                selected: annotation.id == model.editor.selection,
                                onVideo: model.editor.currentDurationMs != nil,
                                showing: annotation.isVisible(atMs: model.editor.currentTimeMs),
                                outside: model.editor.outsideReason(annotation)
                            )
                            .onTapGesture { model.mutate { $0.select(annotation.id) } }
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
