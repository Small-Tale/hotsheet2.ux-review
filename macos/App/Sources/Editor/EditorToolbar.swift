import AppKit
import Combine
import UXReviewKit

/// The editor window's native toolbar (`HS2-WHP4V1`): a unified title bar with the window title
/// on the left and, at the trailing end, the tool picker as one select-one group, **Restore
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
    private var toolGroup: NSToolbarItemGroup?
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
            let tools = EditorTool.allCases
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: tools.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.label) ?? NSImage() },
                selectionMode: .selectOne,
                labels: tools.map(\.label),
                target: self,
                action: #selector(chooseTool(_:))
            )
            group.label = "Tools"
            for (item, tool) in zip(group.subitems, tools) {
                item.toolTip = "\(tool.label) (\(String(tool.shortcut).uppercased()))"
            }
            toolGroup = group
            return group
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

    /// Shows the current tool as selected, and Restore Original only when there is something to
    /// restore.
    func update() {
        if let group = toolGroup, let index = EditorTool.allCases.firstIndex(of: model.editor.tool),
           group.selectedIndex != index {
            group.selectedIndex = index
        }
        if let item = restoreItem {
            let video = model.editor.currentMedia?.kind == .video
            item.isHidden = !(model.editor.currentMedia != nil && model.editor.canRestoreOriginal)
            item.toolTip = video
                ? "Remove this video's crop and trim, including ones from an earlier session; hidden annotations come back"
                : "Remove this capture's crop, including one from an earlier session; hidden annotations come back"
        }
    }

    @objc private func chooseTool(_ sender: NSToolbarItemGroup) {
        let tools = EditorTool.allCases
        guard tools.indices.contains(sender.selectedIndex) else { return }
        model.mutate { $0.setTool(tools[sender.selectedIndex]) }
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
            "tools": toolGroup?.subitems.map(\.label) ?? [],
            "toolTips": toolGroup?.subitems.map { $0.toolTip ?? "" } ?? [],
            "selectedTool": toolGroup
                .map { $0.subitems.indices.contains($0.selectedIndex) ? $0.subitems[$0.selectedIndex].label : "" } ?? "",
            "restoreHidden": restoreItem?.isHidden ?? true,
            "submit": toolbar.items.first { $0.itemIdentifier == Self.submitReview }?.title ?? "",
        ]
    }
}
