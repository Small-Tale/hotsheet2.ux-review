import AppKit
import Combine
import UXReviewKit

extension Notification.Name {
    /// Posted (object: the draft directory URL) after a capture is added to a draft, so an open
    /// editor on that draft picks it up.
    static let reviewDraftChanged = Notification.Name("UXReviewDraftChanged")
}

/// The editor window's observable wrapper around `EditorSession`. Every change goes through
/// `mutate`, which republishes and schedules an autosave. Spec: docs/06-annotation-editor.md.
@MainActor
final class EditorModel: ObservableObject {
    let session: EditorSession
    /// Bumped on every change so SwiftUI and the canvas redraw.
    @Published private(set) var revision = 0
    @Published private(set) var saveError: String?
    /// Asks the inspector to focus the note field (double-click on a shape, Return).
    @Published var focusNoteRequest = 0

    private var saveTask: Task<Void, Never>?
    private var imageCache: [String: (crop: PixelRect?, image: CGImage?)] = [:]
    private var draftChanges: AnyCancellable?

    static let autosaveDelay: Duration = .milliseconds(600)

    init(session: EditorSession) {
        self.session = session
        draftChanges = NotificationCenter.default.publisher(for: .reviewDraftChanged)
            .compactMap { $0.object as? URL }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] directory in
                MainActor.assumeIsolated { self?.draftChanged(directory) }
            }
    }

    var editor: AnnotationEditor { session.editor }

    /// Applies a change to the editor, redraws, and schedules an autosave once no gesture is running.
    func mutate(_ change: (inout AnnotationEditor) -> Void) {
        change(&session.editor)
        revision += 1
        scheduleSave()
    }

    /// The current image for `mediaId` (cropped as edited), cached per crop.
    func image(_ mediaId: String) -> CGImage? {
        let crop = editor.document.crops[mediaId]
        if let cached = imageCache[mediaId], cached.crop == crop { return cached.image }
        let image = session.displayImage(mediaId)
        imageCache[mediaId] = (crop, image)
        return image
    }

    /// Switches to `mediaId`, first picking up media added to the draft since the editor opened.
    func show(mediaId: String) {
        if session.editor.media(mediaId) == nil { draftChanged(session.directory) }
        mutate { $0.show(mediaId: mediaId) }
    }

    func scheduleSave() {
        saveTask?.cancel()
        guard editor.isDirty, editor.gesture == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Saves now (also on window close).
    func save() {
        saveTask?.cancel()
        guard editor.isDirty else { return }
        do {
            try session.save()
            saveError = nil
        } catch {
            saveError = "Couldn't save: \(error)"
        }
        revision += 1
    }

    private func draftChanged(_ directory: URL) {
        guard directory.standardizedFileURL == session.directory.standardizedFileURL else { return }
        do {
            if try !session.reload().isEmpty { revision += 1 }
        } catch {
            saveError = "Couldn't reload the review: \(error)"
        }
    }
}
