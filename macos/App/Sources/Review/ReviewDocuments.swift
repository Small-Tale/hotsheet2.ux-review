import AppKit
import UniformTypeIdentifiers
import UXReviewKit

/// Reviews as macOS documents (`HS2-BKWZ5N`, `HS2-0D87NR`; docs/07 §7.9): File › Open…, Open
/// Recent, Save, Duplicate, and Save As… for `.uxreview` packages. `ReviewDraftStore` does the
/// file work; this owns the panels, the recent list in the app's defaults, and moving open
/// windows along with a review.
@MainActor
enum ReviewDocuments {
    static let contentType = UTType(exportedAs: "com.smalltale.uxreview.review", conformingTo: .package)

    // MARK: Open Recent

    static var recent: RecentReviews { RecentReviews.load(from: AppSettings.defaults) }

    /// Puts `directory` first in Open Recent (an editor opened on it, or it was saved).
    static func note(_ directory: URL) {
        var list = recent
        list.note(directory.path)
        try? list.save(to: AppSettings.defaults)
    }

    static func clearRecent() {
        var list = recent
        list.clear()
        try? list.save(to: AppSettings.defaults)
    }

    /// Fills File › Open Recent: the reviews that still exist, then Clear Menu.
    static func fillRecentMenu(_ menu: NSMenu, store: ReviewDraftStore) {
        menu.removeAllItems()
        for entry in recent.entries(store: store) {
            let item = NSMenuItem(title: entry.title, action: #selector(AppDelegate.openRecentReview(_:)), keyEquivalent: "")
            item.representedObject = entry.directory
            item.toolTip = entry.isUntitled ? "Not saved" : (entry.directory.path as NSString).abbreviatingWithTildeInPath
            item.image = NSWorkspace.shared.icon(for: contentType)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Clear Menu", action: #selector(AppDelegate.clearRecentReviews(_:)), keyEquivalent: "")
    }

    // MARK: Opening

    /// Opens the review in `url` in its editor. A review that can't be read gets an alert.
    static func open(_ url: URL, store: ReviewDraftStore) {
        do {
            let draft = try store.open(url)
            try EditorWindowController.show(directory: draft.directory, store: store)
        } catch {
            alert("Couldn't open “\(url.deletingPathExtension().lastPathComponent)”", error)
        }
    }

    /// File › Open…: one or more `.uxreview` documents.
    static func runOpenPanel(store: ReviewDraftStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [contentType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Open"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            open(url, store: store)
        }
    }

    // MARK: Saving

    /// File › Save: an untitled review asks where to save it, then moves there and keeps
    /// autosaving there. A saved review is already saved in place.
    static func save(_ directory: URL, store: ReviewDraftStore, window: NSWindow?) {
        guard store.isUntitled(directory) else { return }
        runSavePanel(for: directory, store: store, window: window, title: "Save") { destination in
            try store.save(directory, to: destination, replacing: true)
        }
    }

    /// The save panel, then `write` to the chosen place; the review's open windows follow the result.
    static func runSavePanel(
        for directory: URL,
        store: ReviewDraftStore,
        window: NSWindow?,
        title: String,
        write: @escaping (URL) throws -> ReviewDraft
    ) {
        guard let draft = try? store.load(directory) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = draft.bundle.title
        panel.canCreateDirectories = true
        panel.isExtensionHidden = true
        panel.title = title
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            move(directory, store: store, title: draft.bundle.title) { try write(url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// Saves and closes the review's windows, runs `change` (which moves or copies it), and
    /// reopens the editor on the result where it was. A failure reopens nothing and says why.
    static func move(_ directory: URL, store: ReviewDraftStore, title: String, change: () throws -> ReviewDraft) {
        let mediaId = EditorWindowController.currentMediaId(directory: directory)
        let hadSession = ReviewSessionWindowController.isOpen(directory: directory)
        EditorWindowController.close(directory: directory)
        ReviewSessionWindowController.close(directory: directory)
        do {
            let result = try change()
            var list = recent
            // Moved (Save): its Open Recent entry follows. Copied (Save As, Duplicate): a new entry.
            if !FileManager.default.fileExists(atPath: directory.path) {
                list.move(directory.path, to: result.directory.path)
            } else {
                list.note(result.directory.path)
            }
            try? list.save(to: AppSettings.defaults)
            NotificationCenter.default.post(name: .reviewDraftChanged, object: result.directory)
            try EditorWindowController.show(directory: result.directory, store: store, mediaId: mediaId)
            if hadSession { ReviewSessionWindowController.show(draft: result, store: store) }
        } catch {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(ReviewDraftStore.bundleFilename).path) {
                try? EditorWindowController.show(directory: directory, store: store, mediaId: mediaId)
            }
            alert("Couldn't save “\(title)”", error)
        }
    }

    static func alert(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = (error as? ReviewDraftError)?.description ?? (error as NSError).localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}
