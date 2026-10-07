import SwiftUI
import UXReviewKit

/// Capture commands in the menu bar menu. Spec: docs/04-capture.md §4.1.
struct CaptureMenuSection: View {
    @ObservedObject var capture: CaptureCoordinator

    var body: some View {
        switch capture.phase {
        case .idle:
            ForEach(CaptureTarget.allCases, id: \.self) { target in
                Button("Screenshot of \(target.label)") { capture.screenshot(CaptureRequest(kind: .screenshot, target: target)) }
            }
            Menu("Screenshot After Delay") {
                ForEach(CaptureRequest.delayPresets.filter { $0 > 0 }, id: \.self) { delay in
                    Section("\(delay) seconds") {
                        ForEach(CaptureTarget.allCases, id: \.self) { target in
                            Button("\(target.label) after \(delay) s") {
                                capture.screenshot(CaptureRequest(kind: .screenshot, target: target, delaySeconds: delay))
                            }
                        }
                    }
                }
            }
        case let .countingDown(seconds):
            Button("Cancel Capture (\(seconds) s)") { capture.cancel() }
        case .picking:
            Text("Choosing what to capture… (Esc cancels)")
        case .capturing:
            Text("Capturing…")
        }
        Divider()
        if let last = capture.lastCapture {
            Text("Current review: \(last.draft.bundle.media.count) capture(s), last \(last.media.filename)")
        }
        Button("Show Current Review in Finder") { capture.revealCurrentReview() }
        Button("Start New Review") { capture.startNewReview() }
    }
}
