import AppKit
import ApplicationServices
import XCTest

extension UIAppFixture {
    /// Resolve the real app's public AX element, so tests invoke the same increment/decrement
    /// actions as assistive technology instead of simulating an unrelated mouse drag.
    func accessibilityElement(_ identifier: String) throws -> AXUIElement {
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let running = try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.resolvingSymlinksInPath() == bundle
        })
        let root = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        var queue = [root]
        var index = 0
        while index < queue.count, index < 2000 {
            let element = queue[index]
            index += 1
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value) == .success,
               value as? String == identifier { return element }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let elements = children as? [AXUIElement] { queue.append(contentsOf: elements) }
        }
        throw NSError(domain: "UIAppFixture.Accessibility", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "No AX element \(identifier); process trusted=\(AXIsProcessTrusted())",
        ])
    }

    func adjustSidebar(_ action: CFString) throws {
        let element = try accessibilityElement("editor-strip-divider")
        XCTAssertEqual(AXUIElementPerformAction(element, action), .success)
    }
}
