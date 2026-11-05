import AppKit
import CoreGraphics
import XCTest

/// Opening Submit Review from the editor toolbar (HS2-M8PKED). A guest run once clicked
/// Submit Review… right after an import and saw no window within 10 s. The click now waits
/// until the import's open panel is gone and the button is hittable with a stable frame. A
/// failure attaches what the button, sheets, and windows looked like before and after the click,
/// so the next occurrence shows whether the click was lost or the window was late. It never
/// retries: a retry would hide a slow window.
extension UIAppFixture {
    func openSubmit(timeout: TimeInterval = 10) -> XCUIElement {
        let button = app.buttons["Submit Review…"]
        let window = app.windows["Submit Review"]
        let before = submitButtonReadiness(button, timeout: timeout)
        if before.isReady {
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        let opened = before.isReady && window.waitForExistence(timeout: timeout)
        if !opened {
            let diagnostics = """
            Before click: \(before.diagnostics)
            After click (\(before.isReady ? "clicked" : "not clicked")): \(submitSample(button))
            \(environmentSample())
            """
            XCTContext.runActivity(named: "Submit Review window failure") { activity in
                let summary = XCTAttachment(string: diagnostics)
                summary.name = "submit-review-readiness"
                summary.lifetime = .keepAlways
                activity.add(summary)
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "submit-review-ax-tree"
                tree.lifetime = .keepAlways
                activity.add(tree)
            }
            let problem = before.isReady
                ? "The Submit Review window didn't open within \(Int(timeout)) s of clicking Submit Review…"
                : "Submit Review… never became clickable"
            XCTFail("\(problem)\n\(diagnostics)")
        }
        return window
    }

    /// Ready: no sheet over the editor (the import's open panel has closed), and the button
    /// exists, is hittable, and keeps the same frame for three samples. Observes only.
    func submitButtonReadiness(_ button: XCUIElement, timeout: TimeInterval) -> StatusEntryReadiness {
        var previousFrame: CGRect?
        var stableSamples = 0
        var lastSample = "not sampled"
        let ready = wait(timeout: timeout) {
            let sheets = self.app.sheets.count
            let hittable = button.exists && button.isHittable
            let frame = button.exists ? button.frame : .zero
            if sheets == 0, hittable, !frame.isEmpty {
                stableSamples = frame == previousFrame ? stableSamples + 1 : 1
                previousFrame = frame
            } else {
                previousFrame = nil
                stableSamples = 0
            }
            lastSample = self.submitSample(button) + ", stableSamples=\(stableSamples)"
            return stableSamples >= 3
        }
        return StatusEntryReadiness(isReady: ready, diagnostics: "ready=\(ready); \(lastSample)")
    }

    private func submitSample(_ button: XCUIElement) -> String {
        let exists = button.exists
        let windows = app.windows.allElementsBoundByIndex.map { "“\($0.title)”" }.joined(separator: ", ")
        return "buttonExists=\(exists), hittable=\(exists && button.isHittable), enabled=\(exists && button.isEnabled), "
            + "frame=\(exists ? button.frame : .zero), sheets=\(app.sheets.count), windows=[\(windows)]"
    }

    private func environmentSample() -> String {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?["CGSSessionScreenIsLocked"] as? Bool).map(String.init) ?? "unknown"
        let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        return "appState=\(app.state.rawValue), desktopLocked=\(locked), foreground=\(foreground)"
    }
}
