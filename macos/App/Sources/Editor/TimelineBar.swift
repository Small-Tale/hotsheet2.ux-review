import AppKit
import SwiftUI
import UXReviewKit

/// Under the canvas for videos: play/pause, the playhead scrubber, the time ranges of the current
/// video's annotations, frame stepping, and trimming at the playhead. The selected range's ends
/// and the clip's trim handles can be dragged on the track, and the playhead time can be typed.
/// Spec: docs/06-annotation-editor.md §6.10.
struct TimelineBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let editor = model.editor
        let duration = editor.currentDurationMs ?? 0
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 14)
                }
                .help(model.isPlaying ? "Pause (K)" : "Play (K)")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                Button { model.mutate { $0.stepTime(forward: false) } } label: { Image(systemName: "backward.frame") }
                    .help("Step back 0.1 s (,  ⇧ for 1 s)")
                    .accessibilityLabel("Step back")
                Button { model.mutate { $0.stepTime(forward: true) } } label: { Image(systemName: "forward.frame") }
                    .help("Step forward 0.1 s (.  ⇧ for 1 s)")
                    .accessibilityLabel("Step forward")
                HStack(spacing: 4) {
                    TimeField(label: "Playhead time", millis: editor.currentTimeMs) { millis in
                        model.mutate { $0.movePlayhead(to: millis) }
                    }
                    .help("Type a time to move the playhead, for example 1.5 or 0:01.50")
                    Text("/ \(TimeFormat.clock(duration))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { model.mutate { _ = $0.trimStartToPlayhead() } } label: {
                    Label("Trim Start", systemImage: "arrow.right.to.line")
                }
                .help("Cut everything before the playhead (or drag the clip's left handle)")
                .disabled(editor.currentTimeMs <= 0 || duration - editor.currentTimeMs < AnnotationEditor.minimumTrimMs)
                Button { model.mutate { _ = $0.trimEndToPlayhead() } } label: {
                    Label("Trim End", systemImage: "arrow.left.to.line")
                }
                .help("Cut everything after the playhead (or drag the clip's right handle)")
                .disabled(editor.currentTimeMs >= duration || editor.currentTimeMs < AnnotationEditor.minimumTrimMs)
            }
            .buttonStyle(.borderless)
            TimelineTrack(model: model, duration: duration)
                .frame(height: 30)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The scrubber: a track with the playhead, the clip's trim handles at its ends, and below it a
/// lane with each ranged annotation's span (instants as ticks) in its intent color, numbered.
/// Pressing the selected range's ends or a trim handle drags it (`TimelineHitTest`); pressing
/// anywhere else moves the playhead.
struct TimelineTrack: View {
    @ObservedObject var model: EditorModel
    let duration: Int
    /// What the current press grabbed: a handle, or nil for scrubbing.
    @State private var grabbed: TimelineHandle??
    @State private var hoverCursor = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let x = { (millis: Int) -> CGFloat in duration > 0 ? CGFloat(millis) / CGFloat(duration) * width : 0 }
            let trim = model.editor.timelineDrag?.pendingTrim ?? TimeRange(startMs: 0, endMs: duration)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 8)
                    .offset(y: 2)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: x(model.editor.currentTimeMs), height: 8)
                    .offset(y: 2)
                ForEach(ranged, id: \.annotation.id) { entry in
                    rangeMark(entry, x: x)
                }
                trimShade(trim, width: width, x: x)
                trimHandle(at: x(trim.startMs), leading: true)
                trimHandle(at: x(trim.endMs), leading: false)
                Capsule()
                    .fill(Color.accentColor)
                    .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1))
                    .frame(width: 4, height: 30)
                    .offset(x: x(model.editor.currentTimeMs) - 2)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in drag(value, width: width) }
                    .onEnded { _ in endDrag() }
            )
            .onContinuousHover { phase in hover(phase, width: width) }
        }
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue("\(TimeFormat.clock(model.editor.currentTimeMs)) of \(TimeFormat.clock(duration))")
        .accessibilityAdjustableAction { direction in
            model.mutate { $0.stepTime(forward: direction == .increment) }
        }
    }

    // MARK: Dragging

    private var selectedRange: TimeRange? {
        let editor = model.editor
        guard let selected = editor.selectedAnnotation, selected.mediaId == editor.currentMediaId else { return nil }
        return selected.timeRange
    }

    private func time(at x: CGFloat, width: CGFloat) -> Int {
        Int((min(max(x / width, 0), 1) * CGFloat(duration)).rounded())
    }

    private func drag(_ value: DragGesture.Value, width: CGFloat) {
        if grabbed == nil {
            // ← / → step what was pressed here, so the canvas takes the keys back.
            focusEditorCanvas()
            let handle = TimelineHitTest.handle(
                x: value.startLocation.x, y: value.startLocation.y, width: width, durationMs: duration, selectedRange: selectedRange
            )
            grabbed = .some(handle)
            if let handle { model.mutate { _ = $0.beginTimelineDrag(handle) } }
        }
        let millis = time(at: value.location.x, width: width)
        if case .some(.some) = grabbed {
            model.mutate { $0.updateTimelineDrag(toMs: millis) }
        } else {
            model.mutate { $0.movePlayhead(to: millis) }
        }
    }

    private func endDrag() {
        if case .some(.some) = grabbed { model.mutate { $0.endTimelineDrag() } }
        grabbed = nil
    }

    /// A left-right resize cursor over the handles.
    private func hover(_ phase: HoverPhase, width: CGFloat) {
        var overHandle = false
        if case let .active(location) = phase {
            overHandle = TimelineHitTest.handle(
                x: location.x, y: location.y, width: width, durationMs: duration, selectedRange: selectedRange
            ) != nil
        }
        guard overHandle != hoverCursor else { return }
        hoverCursor = overHandle
        if overHandle { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }

    // MARK: Drawing

    private var ranged: [(number: Int, annotation: Annotation)] {
        let editor = model.editor
        return editor.annotations(on: editor.currentMediaId ?? "").compactMap { annotation in
            guard annotation.timeRange != nil, let number = editor.number(of: annotation.id) else { return nil }
            return (number, annotation)
        }
    }

    @ViewBuilder
    private func rangeMark(_ entry: (number: Int, annotation: Annotation), x: (Int) -> CGFloat) -> some View {
        let range = entry.annotation.timeRange ?? TimeRange(startMs: 0, endMs: 0)
        let selected = entry.annotation.id == model.editor.selection
        let color = Color(cgColor: IntentPalette.color(entry.annotation.primaryIntent))
        let width = max(x(range.endMs) - x(range.startMs), 5)
        let left = x(range.startMs) - (width == 5 ? 2.5 : 0)
        RoundedRectangle(cornerRadius: 2)
            .fill(color.opacity(selected ? 0.95 : 0.6))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected ? Color.primary : Color.clear, lineWidth: 1))
            .frame(width: width, height: 13)
            .overlay(alignment: .leading) {
                Text("\(entry.number)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(IntentPalette.usesDarkText(entry.annotation.primaryIntent) ? Color.black : Color.white)
                    .padding(.leading, 5)
                    .opacity(width >= 18 ? 1 : 0)
            }
            .offset(x: left, y: 15)
            .allowsHitTesting(false)
        if selected {
            // Grips on the selected range's ends: drag them to change when it shows.
            rangeGrip(at: x(range.startMs))
            rangeGrip(at: x(range.endMs))
        }
    }

    private func rangeGrip(at position: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(Color.black.opacity(0.55), lineWidth: 1))
            .frame(width: 4, height: 15)
            .offset(x: position - 2, y: 14)
            .allowsHitTesting(false)
    }

    /// While a trim handle is dragged, what would be cut is dimmed.
    @ViewBuilder
    private func trimShade(_ trim: TimeRange, width: CGFloat, x: (Int) -> CGFloat) -> some View {
        if model.editor.timelineDrag?.pendingTrim != nil {
            Rectangle().fill(Color.black.opacity(0.45))
                .frame(width: max(x(trim.startMs), 0), height: 30)
                .allowsHitTesting(false)
            Rectangle().fill(Color.black.opacity(0.45))
                .frame(width: max(width - x(trim.endMs), 0), height: 30)
                .offset(x: x(trim.endMs))
                .allowsHitTesting(false)
        }
    }

    /// The clip's in or out point: a bracket on the scrubber row.
    private func trimHandle(at position: CGFloat, leading: Bool) -> some View {
        TrimBracket(leading: leading)
            .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: 5, height: 12)
            .offset(x: leading ? position : position - 5, y: 0)
            .allowsHitTesting(false)
    }
}

/// `[` or `]`.
struct TrimBracket: SwiftUI.Shape {
    let leading: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spine = leading ? rect.minX + 1 : rect.maxX - 1
        let tip = leading ? rect.maxX : rect.minX
        path.move(to: CGPoint(x: tip, y: rect.minY + 1))
        path.addLine(to: CGPoint(x: spine, y: rect.minY + 1))
        path.addLine(to: CGPoint(x: spine, y: rect.maxY - 1))
        path.addLine(to: CGPoint(x: tip, y: rect.maxY - 1))
        return path
    }
}

/// Makes the key window's annotation canvas first responder, so its keys (← / →, tools) work.
@MainActor
func focusEditorCanvas() {
    guard let window = NSApp.keyWindow, let canvas = window.contentView?.firstDescendant(AnnotationCanvasView.self) else { return }
    window.makeFirstResponder(canvas)
}

/// A time the reviewer can type (`1.5`, `0:01.50`, `1500 ms`; `TimeFormat.parse`). It shows
/// `millis` while not being edited. Return commits; a time that doesn't parse beeps and reverts.
/// Afterwards focus goes back to the canvas, so its keys work again. While it has focus but no
/// typed change, ← / → go to the canvas (`focusedUnedited`, docs/06 §6.4).
struct TimeField: View {
    let label: String
    let millis: Int
    let commit: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    /// True while a time field has focus and still shows its time unchanged. Only one field has
    /// focus at a time, so one flag serves every editor window.
    @MainActor static var focusedUnedited = false

    private func reportEditing() {
        Self.focusedUnedited = focused && text == TimeFormat.clock(millis)
    }

    var body: some View {
        TextField(label, text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.callout.monospacedDigit())
            .frame(width: 72)
            .focused($focused)
            .accessibilityLabel(label)
            .onAppear { text = TimeFormat.clock(millis) }
            .onDisappear { if focused { Self.focusedUnedited = false } }
            .onChange(of: millis) { old, new in
                // An unedited field follows the time even while focused.
                if !focused || text == TimeFormat.clock(old) { text = TimeFormat.clock(new) }
                reportEditing()
            }
            .onChange(of: focused) {
                if !focused { text = TimeFormat.clock(millis) }
                reportEditing()
            }
            .onChange(of: text) { reportEditing() }
            .onSubmit {
                let typed = TimeFormat.parse(text)
                focused = false
                text = TimeFormat.clock(millis)
                if let typed { commit(typed) } else { NSSound.beep() }
                focusEditorCanvas()
            }
    }
}
