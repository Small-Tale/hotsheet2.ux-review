import AppKit
import Combine
import UXReviewKit

/// The editor window's native toolbar (`HS2-WHP4V1`): a unified title bar with the window title
/// on the left and, at the trailing end, the tool picker as one select-one group (one glass
/// capsule of icon buttons without inner dividers, like Preview's markup tools, `HS2-YE2X53`), **Restore
/// Original** (only while the capture is cropped or the video trimmed), and **Submit Review…**
/// as the prominent action. macOS 26 draws the items as Liquid Glass. Spec: docs/06 §6.1.
@MainActor
final class EditorToolbar: NSObject, NSToolbarDelegate {
    static let tools = NSToolbarItem.Identifier("UXReview.tools")
    static let restoreOriginal = NSToolbarItem.Identifier("UXReview.restoreOriginal")
    static let submitReview = NSToolbarItem.Identifier("UXReview.submitReview")

    let toolbar = NSToolbar(identifier: "UXReviewEditor")
    private let model: EditorModel
    private let submit: () -> Void
    private var toolButtons: [NSButton] = []
    private var toolMenu: NSMenu?
    private var restoreItem: NSToolbarItem?
    private var changes: AnyCancellable?

    init(model: EditorModel, submit: @escaping () -> Void) {
        self.model = model
        self.submit = submit
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // Follow tool changes made with the keyboard (R, F, A, I, S, C, V) and crop/trim changes.
        changes = model.$revision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
    }

    /// Installs the toolbar on `window` with the unified, title-on-the-left style.
    func install(on window: NSWindow) {
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        update()
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.tools, .space, Self.restoreOriginal, Self.submitReview]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.tools:
            return makeToolsItem(identifier)
        case Self.restoreOriginal:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Restore Original"
            item.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle", accessibilityDescription: "Restore Original")
            item.target = self
            item.action = #selector(restoreOriginal(_:))
            restoreItem = item
            return item
        case Self.submitReview:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Submit Review…"
            item.title = "Submit Review…"
            item.toolTip = "Save and open the Submit Review window for this review (⌘↩)"
            item.style = .prominent
            item.target = self
            item.action = #selector(submitReview(_:))
            return item
        default:
            return nil
        }
    }

    /// The tool picker: one item whose view is a row of toggle buttons, so the toolbar draws it as
    /// a single glass capsule with no dividers (a select-one `NSToolbarItemGroup` is drawn as a
    /// segmented control with a divider between every tool). When the toolbar overflows, the
    /// tools show as a Tools menu.
    private func makeToolsItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let tools = EditorTool.allCases
        toolButtons = tools.enumerated().map { index, tool in
            let image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.label) ?? NSImage()
            let button = NSButton(image: image, target: self, action: #selector(chooseTool(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .toolbar
            button.showsBorderOnlyWhileMouseInside = true
            button.tag = index
            button.toolTip = tool.toolTip
            button.setAccessibilityLabel(tool.label)
            button.setAccessibilityHelp(tool.toolTip)
            return button
        }
        let stack = NSStackView(views: toolButtons)
        stack.spacing = 4
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel("Tools")
        let menu = NSMenu(title: "Tools")
        for (index, tool) in tools.enumerated() {
            let item = NSMenuItem(title: tool.label, action: #selector(chooseTool(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        toolMenu = menu
        let form = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        form.submenu = menu
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Tools"
        item.view = stack
        item.menuFormRepresentation = form
        return item
    }

    /// Shows the current tool as selected, and Restore Original only when there is something to
    /// restore.
    func update() {
        let current = EditorTool.allCases.firstIndex(of: model.editor.tool)
        for button in toolButtons {
            button.state = button.tag == current ? .on : .off
        }
        for item in toolMenu?.items ?? [] {
            item.state = item.tag == current ? .on : .off
        }
        if let item = restoreItem {
            let video = model.editor.currentMedia?.kind == .video
            item.isHidden = !(model.editor.currentMedia != nil && model.editor.canRestoreOriginal)
            item.toolTip = video
                ? "Remove this video's crop and trim, including ones from an earlier session; hidden annotations come back"
                : "Remove this capture's crop, including one from an earlier session; hidden annotations come back"
        }
    }

    /// A tool button or Tools menu item; its tag is the tool's index. Choosing the current tool
    /// again keeps it selected (the button's own toggle is undone by `update`).
    @objc private func chooseTool(_ sender: Any?) {
        let tools = EditorTool.allCases
        guard let tag = (sender as? NSButton)?.tag ?? (sender as? NSMenuItem)?.tag, tools.indices.contains(tag) else { return }
        model.mutate { $0.setTool(tools[tag]) }
        update()
    }

    /// Clicks the tool button for `tool`, as a mouse click does, for `--render-ui-previews`.
    func clickToolButton(_ tool: EditorTool) {
        toolButtons.first { $0.tag == EditorTool.allCases.firstIndex(of: tool) }?.performClick(nil)
    }

    @objc private func restoreOriginal(_: Any?) {
        model.mutate { _ = $0.restoreOriginal() }
    }

    @objc private func submitReview(_: Any?) {
        submit()
    }

    /// The toolbar as it stands, for `--render-ui-previews` (`editor-toolbar.json`).
    func describe() -> [String: Any] {
        [
            "identifiers": toolbar.items.map(\.itemIdentifier.rawValue),
            "tools": toolButtons.map { $0.accessibilityLabel() ?? "" },
            "toolTips": toolButtons.map { $0.toolTip ?? "" },
            "toolSymbols": EditorTool.allCases.map(\.symbol),
            "toolsAreOneView": toolbar.items.first { $0.itemIdentifier == Self.tools }?.view is NSStackView,
            "selectedTools": toolButtons.filter { $0.state == .on }.map { $0.accessibilityLabel() ?? "" },
            "selectedTool": toolButtons.first { $0.state == .on }?.accessibilityLabel() ?? "",
            "menuTools": toolMenu?.items.map(\.title) ?? [],
            "restoreHidden": restoreItem?.isHidden ?? true,
            "submit": toolbar.items.first { $0.itemIdentifier == Self.submitReview }?.title ?? "",
        ]
    }
}
