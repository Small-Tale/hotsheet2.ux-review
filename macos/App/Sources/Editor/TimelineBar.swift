import AppKit
import SwiftUI
import UXReviewKit

/// Under the canvas for videos: play/pause, the playhead scrubber, the time ranges of the current
/// video's annotations, and trimming at the playhead. Stepping is on the keyboard. The selected range's ends
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
                // No step buttons (HS2-QXNXHS): ← / → step a frame, `,` / `.` 0.1 s (⇧: 1 s).
                HStack(spacing: 4) {
                    TimeField(label: "Playhead time", millis: editor.currentTimeMs) { millis in
                        model.mutate { $0.movePlayhead(to: millis) }
                    }
                    .help("Type a time to move the playhead, for example 1.5 or 0:01.50")
                    // Never wrapped: in a narrow window the trim buttons give way first (HS2-XSXV5E).
                    Text("/ \(TimeFormat.clock(duration))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 8)
                trimControls
            }
            .buttonStyle(.borderless)
            TimelineTrack(model: model, duration: duration)
                .frame(height: 30)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Trim mode (`HS2-ECE7WY`): **Trim** starts it; in it, **Cancel** (Esc) and **Trim** (Return).
    @ViewBuilder private var trimControls: some View {
        if model.editor.trimMode != nil {
            HStack(spacing: 8) {
                Button("Cancel") { model.mutate { _ = $0.cancelTrimMode() } }
                    .help("Leave the video as it was (Esc)")
                Button("Trim") { model.mutate { _ = $0.commitTrimMode() } }
                    .buttonStyle(.borderedProminent)
                    .tint(TrimModeStyle.color)
                    .help("Keep the part between the yellow handles (Return)")
            }
            .controlSize(.small)
            .fixedSize()
        } else {
            Button { model.mutate { _ = $0.enterTrimMode() } } label: {
                Label("Trim", systemImage: "scissors")
            }
            .help("Trim the video: drag the yellow handles to keep a part of it")
            .disabled(!model.editor.canTrim)
            .fixedSize()
        }
    }
}

/// Trim mode's yellow, as in QuickTime Player's trim bar.
enum TrimModeStyle {
    static let color = Color(red: 0.98, green: 0.78, blue: 0.16)
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
                .opacity(model.editor.trimMode == nil ? 1 : 0.3)
                if let mode = model.editor.trimMode {
                    trimModeOverlay(mode.range, width: width, x: x)
                }
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
        guard editor.trimMode == nil, let selected = editor.selectedAnnotation,
              selected.mediaId == editor.currentMediaId else { return nil }
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
                x: value.startLocation.x, y: value.startLocation.y, width: width, durationMs: duration,
                selectedRange: selectedRange, trim: model.editor.trimMode?.range
            )
            grabbed = .some(handle)
            if let handle, !handle.isTrim { model.mutate { _ = $0.beginTimelineDrag(handle) } }
        }
        let millis = time(at: value.location.x, width: width)
        if case let .some(.some(handle)) = grabbed, handle.isTrim {
            // A Trim-mode handle: moves the mode's range; nothing is applied until Trim.
            model.mutate { $0.setTrimModeEnd(handle, toMs: millis) }
        } else if case .some(.some) = grabbed {
            model.mutate { $0.updateTimelineDrag(toMs: millis) }
        } else {
            model.mutate { $0.movePlayhead(to: millis) }
        }
    }

    private func endDrag() {
        if case let .some(.some(handle)) = grabbed, !handle.isTrim { model.mutate { $0.endTimelineDrag() } }
        grabbed = nil
    }

    /// A left-right resize cursor over the handles.
    private func hover(_ phase: HoverPhase, width: CGFloat) {
        var overHandle = false
        if case let .active(location) = phase {
            overHandle = TimelineHitTest.handle(
                x: location.x, y: location.y, width: width, durationMs: duration,
                selectedRange: selectedRange, trim: model.editor.trimMode?.range
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
            // Ranges outside the trim are hidden (HS2-71SSJG); the rest are drawn clamped to the clip.
            guard annotation.timeRange != nil, !editor.isOutsideEdit(annotation), let number = editor.number(of: annotation.id)
            else { return nil }
            return (number, annotation)
        }
    }

    @ViewBuilder
    private func rangeMark(_ entry: (number: Int, annotation: Annotation), x: (Int) -> CGFloat) -> some View {
        let duration = model.editor.currentDurationMs ?? 0
        let raw = entry.annotation.timeRange ?? TimeRange(startMs: 0, endMs: 0)
        let range = TimeRange(startMs: min(max(raw.startMs, 0), duration), endMs: min(max(raw.endMs, 0), duration))
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

    /// Trim mode: the kept part framed in yellow with a handle at each end, the rest dimmed.
    @ViewBuilder
    private func trimModeOverlay(_ range: TimeRange, width: CGFloat, x: (Int) -> CGFloat) -> some View {
        let start = x(range.startMs), end = x(range.endMs)
        Rectangle().fill(Color.black.opacity(0.4))
            .frame(width: max(start, 0), height: 30)
            .allowsHitTesting(false)
        Rectangle().fill(Color.black.opacity(0.4))
            .frame(width: max(width - end, 0), height: 30)
            .offset(x: end)
            .allowsHitTesting(false)
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(TrimModeStyle.color, lineWidth: 3)
            .frame(width: max(end - start, 6), height: 30)
            .offset(x: start)
            .allowsHitTesting(false)
        ForEach([start, end - 8], id: \.self) { left in
            RoundedRectangle(cornerRadius: 3)
                .fill(TrimModeStyle.color)
                .overlay(Capsule().fill(Color.black.opacity(0.45)).frame(width: 2, height: 12))
                .frame(width: 8, height: 30)
                .offset(x: left)
                .allowsHitTesting(false)
        }
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
