import AppKit
import CoreGraphics
import XCTest

struct StatusEntryReadiness {
    let isReady: Bool
    let diagnostics: String
}

extension UIAppFixture {
    func openStatusMenu() {
        let status = app.statusItems["status-item"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "UX Review status item missing; check UI automation permissions")
        status.click()
        waitForStatusEntry("Settings…")
    }

    func clickStatusEntry(_ title: String) {
        let entry = waitForStatusEntry(title)
        // MenuItem.click() traverses/reopens ancestor menus, which can time out even
        // when this status menu is already visible. Click the ready item's center instead.
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    @discardableResult
    private func waitForStatusEntry(_ title: String) -> XCUIElement {
        let result = statusEntryReadiness(title)
        if !result.isReady {
            XCTContext.runActivity(named: "Status menu readiness failure") { activity in
                let attachment = XCTAttachment(string: result.diagnostics)
                attachment.name = "status-menu-readiness"
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
        XCTAssertTrue(result.isReady, "Status menu entry \(title) never became hittable with stable geometry\n\(result.diagnostics)")
        return app.statusItems["status-item"].menus.firstMatch.menuItems["menu-\(title)"]
    }

    /// Observes only: callers decide whether a failure is expected. Never reopens or retries.
    func statusEntryReadiness(_ title: String, timeout: TimeInterval = 5) -> StatusEntryReadiness {
        let status = app.statusItems["status-item"]
        let menu = status.menus.firstMatch
        let entry = menu.menuItems["menu-\(title)"]
        var previousFrame: CGRect?
        var stableSamples = 0
        var lastSample = "not sampled"
        let ready = wait(timeout: timeout) {
            let exists = entry.exists
            let hittable = exists && entry.isHittable
            let frame = exists ? entry.frame : .zero
            let valid = !frame.isEmpty && !frame.isInfinite && !frame.isNull
            if hittable, valid {
                stableSamples = frame == previousFrame ? stableSamples + 1 : 1
                previousFrame = frame
            } else {
                previousFrame = nil
                stableSamples = 0
            }
            lastSample = "entryExists=\(exists), hittable=\(hittable), frame=\(frame), stableSamples=\(stableSamples)"
            return stableSamples >= 3
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?["CGSSessionScreenIsLocked"] as? Bool).map(String.init) ?? "unknown"
        let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        let diagnostics = """
        Requested entry: \(title)
        ready=\(ready), appState=\(app.state.rawValue), desktopLocked=\(locked), foreground=\(foreground)
        statusExists=\(status.exists), menuExists=\(menu.exists)
        Last sample: \(lastSample)
        """
        return StatusEntryReadiness(isReady: ready, diagnostics: diagnostics)
    }
}
