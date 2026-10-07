import AppKit
import UXReviewKit

/// Auto-scroll for the canvas (docs/06-annotation-editor.md §6.2.1): while a gesture runs, a 60 Hz
/// timer pans the canvas when the dragging pointer is near or past an edge, and moves the gesture
/// with it (`EditorModel.autoScrollStep`), so it keeps going while the mouse is held still.
@MainActor
final class CanvasAutoScroller {
    /// Where the dragging pointer last was, in canvas coordinates (it may be outside the canvas).
    private var pointer: CGPoint?
    private weak var model: EditorModel?
    private var timer: Timer?
    private var lastTick = Date()

    /// Each drag event: remembers the pointer and starts the timer if it isn't running.
    func track(_ pointer: CGPoint, model: EditorModel) {
        self.pointer = pointer
        self.model = model
        guard timer == nil else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Mouse up (or the gesture ended some other way, such as Esc).
    func stop() {
        timer?.invalidate()
        timer = nil
        pointer = nil
    }

    private func fire() {
        let now = Date()
        let elapsed = min(now.timeIntervalSince(lastTick), 0.1) // a stalled run loop never jumps far
        lastTick = now
        guard let model, model.editor.gesture != nil, let pointer else { return stop() }
        model.autoScrollStep(pointer: pointer, elapsed: elapsed)
    }
}
