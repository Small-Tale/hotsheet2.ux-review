import AppKit
import UXReviewKit

/// The app menu bar, shown while a UX Review window is open (the app is a regular app then;
/// `DockPresence`). File actions go through the responder chain: an editor or Submit Review
/// window answers for *its* draft, and `AppDelegate` answers for the current draft otherwise.
/// Spec: docs/05-start-and-settings.md §5.1.1.
@MainActor
enum MainMenu {
    /// Keeps the Capture menu's delegate alive (NSMenu holds its delegate weakly).
    private static var captureMenu: DynamicMenu?

    static func install(captureEntries: @escaping @MainActor () -> [MenuEntry], perform: @escaping @MainActor (MenuCommand) -> Void) {
        let capture = DynamicMenu(title: "Capture", entries: captureEntries, perform: perform)
        captureMenu = capture
        let window = windowMenu()
        let main = NSMenu(title: "Main Menu")
        for menu in [appMenu(), fileMenu(), editMenu(), viewMenu(), capture.menu, window] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "UX Review")
        menu.addItem(withTitle: "About UX Review", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide UX Review", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit UX Review", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New Review", action: #selector(AppDelegate.newReview(_:)), keyEquivalent: "n")
        menu.addItem(withTitle: "Add Media…", action: #selector(AppDelegate.addMedia(_:)), keyEquivalent: "o")
        menu.addItem(withTitle: "Draft Reviews…", action: #selector(AppDelegate.showDraftReviews(_:)), keyEquivalent: "o")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Save", action: #selector(AnnotationCanvasView.saveDocument(_:)), keyEquivalent: "s")
        // Disabled in a Submit Review window, so ⌘↩ reaches its Submit button instead.
        menu.addItem(withTitle: "Submit Review…", action: #selector(AppDelegate.submitReview(_:)), keyEquivalent: "\r")
        menu.addItem(withTitle: "Show Review in Finder", action: #selector(AppDelegate.revealReview(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: #selector(AnnotationCanvasView.undo(_:)), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: #selector(AnnotationCanvasView.redo(_:)), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(withTitle: "Duplicate", action: #selector(AnnotationCanvasView.duplicate(_:)), keyEquivalent: "d")
        menu.addItem(.separator())
        // Both act on the media strip's selection and name its size ("Remove 3 Captures…").
        menu.addItem(
            withTitle: "Remove Capture from Review…",
            action: #selector(EditorWindowController.removeCapture(_:)),
            keyEquivalent: ""
        )
        // ⌘⌫ removes without asking. The item is disabled while text is being edited, so the key
        // then reaches the text and keeps deleting to the start of the line (docs/06 §6.7.2).
        menu.addItem(
            withTitle: "Remove Capture Now",
            action: #selector(EditorWindowController.removeSelectedCaptures(_:)),
            keyEquivalent: "\u{8}"
        )
        return menu
    }

    /// Zoom for the editor window's canvas, with Preview's shortcuts (`HS2-8QBS4V`). The editor
    /// window answers; without one the items are disabled.
    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Actual Size", action: #selector(EditorWindowController.zoomToActualSize(_:)), keyEquivalent: "0")
        menu.addItem(withTitle: "Zoom to Fit", action: #selector(EditorWindowController.zoomToFit(_:)), keyEquivalent: "9")
        menu.addItem(withTitle: "Zoom In", action: #selector(EditorWindowController.zoomIn(_:)), keyEquivalent: "+")
        // ⌘= (no Shift) zooms in too, as in Preview and Safari; hidden.
        let equals = menu.addItem(withTitle: "Zoom In", action: #selector(EditorWindowController.zoomIn(_:)), keyEquivalent: "=")
        equals.isHidden = true
        equals.allowsKeyEquivalentWhenHidden = true
        menu.addItem(withTitle: "Zoom Out", action: #selector(EditorWindowController.zoomOut(_:)), keyEquivalent: "-")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Draft Reviews…", action: #selector(AppDelegate.showDraftReviews(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }
}

/// A menu rebuilt from `MenuEntry` descriptions every time it opens.
@MainActor
final class DynamicMenu: NSObject, NSMenuDelegate {
    let menu: NSMenu
    private let entries: @MainActor () -> [MenuEntry]
    private let perform: @MainActor (MenuCommand) -> Void

    init(title: String, entries: @escaping @MainActor () -> [MenuEntry], perform: @escaping @MainActor (MenuCommand) -> Void) {
        menu = NSMenu(title: title)
        self.entries = entries
        self.perform = perform
        super.init()
        menu.delegate = self
        rebuild()
    }

    func rebuild() {
        menu.removeAllItems()
        MenuRendering.items(entries(), perform: perform).forEach(menu.addItem)
    }

    func menuNeedsUpdate(_: NSMenu) {
        rebuild()
    }
}
