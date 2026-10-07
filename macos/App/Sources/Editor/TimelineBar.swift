import SwiftUI
import UXReviewKit

/// Under the canvas for videos: play/pause, the playhead scrubber, the time ranges of the current video's
/// annotations, frame stepping, and trimming at the playhead. Spec: docs/06-annotation-editor.md §6.10.
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
                Text("\(TimeFormat.clock(editor.currentTimeMs)) / \(TimeFormat.clock(duration))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { model.mutate { _ = $0.trimStartToPlayhead() } } label: {
                    Label("Trim Start", systemImage: "arrow.right.to.line")
                }
                .help("Cut everything before the playhead")
                .disabled(editor.currentTimeMs <= 0 || duration - editor.currentTimeMs < AnnotationEditor.minimumTrimMs)
                Button { model.mutate { _ = $0.trimEndToPlayhead() } } label: {
                    Label("Trim End", systemImage: "arrow.left.to.line")
                }
                .help("Cut everything after the playhead")
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

/// The scrubber: a track with the playhead, and below it a lane with each ranged annotation's span
/// (instants as ticks) in its intent color, numbered. Click or drag anywhere to move the playhead.
struct TimelineTrack: View {
    @ObservedObject var model: EditorModel
    let duration: Int

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
                Capsule()
                    .fill(Color.accentColor)
                    .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1))
                    .frame(width: 4, height: 30)
                    .offset(x: x(model.editor.currentTimeMs) - 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let fraction = min(max(value.location.x / width, 0), 1)
                model.mutate { $0.setCurrentTime(Int((fraction * CGFloat(duration)).rounded())) }
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue("\(TimeFormat.clock(model.editor.currentTimeMs)) of \(TimeFormat.clock(duration))")
        .accessibilityAdjustableAction { direction in
            model.mutate { $0.stepTime(forward: direction == .increment) }
        }
    }

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
        RoundedRectangle(cornerRadius: 2)
            .fill(color.opacity(selected ? 0.95 : 0.6))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected ? Color.primary : Color.clear, lineWidth: 1))
            .frame(width: width, height: 13)
            .overlay(alignment: .leading) {
                Text("\(entry.number)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(IntentPalette.usesDarkText(entry.annotation.primaryIntent) ? Color.black : Color.white)
                    .padding(.leading, 3)
                    .opacity(width >= 14 ? 1 : 0)
            }
            .offset(x: x(range.startMs) - (width == 5 ? 2.5 : 0), y: 15)
            .allowsHitTesting(false)
    }
}
