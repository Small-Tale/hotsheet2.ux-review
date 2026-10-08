import AppKit
import UXReviewKit

/// Turns `MenuEntry` descriptions (UXReviewKit `AppMenus`) into NSMenu items for the menu bar
/// menu and the app's Capture menu. Spec: docs/05-start-and-settings.md §5.1.
@MainActor
enum MenuRendering {
    static func items(_ entries: [MenuEntry], perform: @escaping @MainActor (MenuCommand) -> Void) -> [NSMenuItem] {
        // Rows drawn by UX Review line their titles up with AppKit's, which move right when a
        // sibling is checked (`HS2-T4RS7M`). Menus are rebuilt each time they open.
        let titleInset = MenuMetrics.titleInset(among: entries)
        return entries.map { item($0, titleInset: titleInset, perform: perform) }
    }

    static func item(
        _ entry: MenuEntry,
        titleInset: Double = MenuMetrics.titleInset,
        perform: @escaping @MainActor (MenuCommand) -> Void
    ) -> NSMenuItem {
        switch entry {
        case let .label(title):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .separator:
            return .separator()
        case let .action(title, command, shortcut):
            let item = CommandMenuItem(title: title, command: command, perform: perform)
            if let shortcut { item.apply(shortcut) }
            return item
        case let .toggle(title, isOn, command):
            let item = CommandMenuItem(title: title, command: command, perform: perform)
            item.state = isOn ? .on : .off
            return item
        case let .submenu(title, children):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items(children, perform: perform).forEach(menu.addItem)
            item.submenu = menu
            return item
        case let .picker(title, choices, selected):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.view = MenuChoicesView(title: title, choices: choices, selected: selected, titleInset: titleInset, perform: perform)
            return item
        }
    }
}

/// A menu item that runs a `MenuCommand`. It is its own target (menus retain their items).
final class CommandMenuItem: NSMenuItem {
    let command: MenuCommand
    private let perform: @MainActor (MenuCommand) -> Void

    init(title: String, command: MenuCommand, perform: @escaping @MainActor (MenuCommand) -> Void) {
        self.command = command
        self.perform = perform
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError("not used") }

    @objc private func fire() {
        let (perform, command) = (perform, command)
        MainActor.assumeIsolated { perform(command) }
    }

    func apply(_ shortcut: MenuShortcut) {
        keyEquivalent = shortcut.key
        keyEquivalentModifierMask = NSEvent.ModifierFlags(shortcut.modifiers)
    }
}

extension NSEvent.ModifierFlags {
    init(_ modifiers: Set<Hotkey.Modifier>) {
        self = []
        if modifiers.contains(.control) { insert(.control) }
        if modifiers.contains(.option) { insert(.option) }
        if modifiers.contains(.shift) { insert(.shift) }
        if modifiers.contains(.command) { insert(.command) }
    }
}

/// "Capture   [ Screen | Window | Region ]": a titled select-one segmented control inside a
/// menu, showing the current choice. Choosing a segment runs its command at once and leaves the
/// menu open, so the reviewer can go on to a capture item.
final class MenuChoicesView: NSView {
    static let minimumWidth: CGFloat = 220
    private let choices: [MenuChoice]
    private let perform: @MainActor (MenuCommand) -> Void
    let control: NSSegmentedControl
    /// Where the title starts, lined up with ordinary items' titles (`MenuMetrics`).
    let titleInset: CGFloat

    init(
        title: String,
        choices: [MenuChoice],
        selected: Int?,
        titleInset: Double = MenuMetrics.titleInset,
        perform: @escaping @MainActor (MenuCommand) -> Void
    ) {
        self.choices = choices
        self.perform = perform
        self.titleInset = titleInset
        control = NSSegmentedControl(labels: choices.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: CGRect(x: 0, y: 0, width: Self.minimumWidth, height: 28))
        // Stretches to the menu's width, so the control stays right-aligned with the shortcuts.
        autoresizingMask = [.width]
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .labelColor
        control.controlSize = .small
        control.target = self
        control.action = #selector(choose(_:))
        control.setAccessibilityLabel(title)
        for (index, choice) in choices.enumerated() {
            control.setToolTip(choice.accessibilityLabel, forSegment: index)
            control.setWidth(64, forSegment: index)
        }
        if let selected, choices.indices.contains(selected) {
            control.selectedSegment = selected
        }
        for view in [label, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Lines up with the titles of ordinary items, and the control with their shortcuts.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: titleInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 16),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailingInset),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // Wide enough for the title, the gap, and every segment (the menu grows to fit).
        let needed = titleInset + label.intrinsicContentSize.width + 16 + control.intrinsicContentSize.width
            + MenuMetrics.trailingInset
        frame.size.width = max(Self.minimumWidth, ceil(needed))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    /// Simulates choosing segment `index` (UI previews and tests).
    func choose(segment index: Int) {
        guard choices.indices.contains(index) else { return }
        control.selectedSegment = index
        perform(choices[index].command)
    }

    @objc private func choose(_ sender: NSSegmentedControl) {
        choose(segment: sender.selectedSegment)
    }
}

/// A plain description of an NSMenu (titles, shortcuts, checkmarks, submenus, custom rows) for
/// `--render-ui-previews` (`menus.json`), so menu structure can be checked without a display.
@MainActor
enum MenuDump {
    static func describe(_ menu: NSMenu) -> [[String: Any]] {
        menu.items.map { item in
            if item.isSeparatorItem { return ["separator": true] }
            var entry: [String: Any] = ["title": item.title]
            if !item.keyEquivalent.isEmpty {
                entry["shortcut"] = shortcut(item)
            }
            if item.state == .on { entry["checked"] = true }
            if item.action == nil, item.submenu == nil, item.view == nil { entry["label"] = true }
            if let action = item.action { entry["action"] = NSStringFromSelector(action) }
            if let row = item.view as? MenuChoicesView {
                entry["choices"] = (0 ..< row.control.segmentCount).map { row.control.label(forSegment: $0) ?? "" }
                entry["titleInset"] = row.titleInset
                if row.control.selectedSegment >= 0 {
                    entry["selected"] = row.control.label(forSegment: row.control.selectedSegment) ?? ""
                }
            }
            if let submenu = item.submenu {
                // Dynamic menus fill themselves when they open.
                submenu.delegate?.menuNeedsUpdate?(submenu)
                entry["submenu"] = describe(submenu)
            }
            return entry
        }
    }

    private static func shortcut(_ item: NSMenuItem) -> String {
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        switch item.keyEquivalent {
        case "\r": return text + "↩"
        case "\u{8}": return text + "⌫"
        case " ": return text + "Space"
        default: return text + item.keyEquivalent.uppercased()
        }
    }
}
