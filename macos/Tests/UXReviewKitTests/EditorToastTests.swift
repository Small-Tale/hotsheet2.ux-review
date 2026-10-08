import Foundation
import Testing
@testable import UXReviewKit

/// HS2-KJCJWX: the editor's toasts. Spec: docs/06-annotation-editor.md §6.1.
struct EditorToastTests {
    @Test func saveErrorsWinAndRoutineStatesShowNothing() {
        #expect(EditorToast.current(message: nil, saveError: nil) == nil)
        #expect(EditorToast.current(message: "", saveError: "") == nil)
        #expect(EditorToast.current(message: "Trimmed to 1.5 s.", saveError: nil) == EditorToast("Trimmed to 1.5 s."))
        #expect(
            EditorToast.current(message: "Trimmed to 1.5 s.", saveError: "Couldn't save: disk full")
                == EditorToast("Couldn't save: disk full", kind: .error)
        )
        #expect(EditorToast("x").duration == EditorToast.infoDuration)
        #expect(EditorToast("x", kind: .error).duration == nil)
    }

    /// Show → expire → hidden; clear → the same message again shows again; a new message
    /// replaces an expired one; repeated expiry is harmless; errors never expire.
    @Test func presenterWalksShowExpireAndRefill() {
        let trimmed = EditorToast("Trimmed to 1.5 s.")
        let hint = EditorToast("Drag a new crop.")
        let error = EditorToast("Couldn't save", kind: .error)
        var presenter = ToastPresenter()
        #expect(presenter.visible(nil) == nil)

        presenter.changed()
        #expect(presenter.visible(trimmed) == trimmed)
        presenter.expire(trimmed)
        #expect(presenter.visible(trimmed) == nil)
        presenter.expire(trimmed)
        #expect(presenter.visible(trimmed) == nil)

        // Cleared, then the same text again (another trim to the same length).
        presenter.changed()
        #expect(presenter.visible(nil) == nil)
        presenter.changed()
        #expect(presenter.visible(trimmed) == trimmed)

        // A different message while one has expired.
        presenter.expire(trimmed)
        presenter.changed()
        #expect(presenter.visible(hint) == hint)

        // An error outlives any timer, and a stale expiry for another toast doesn't hide it.
        presenter.changed()
        presenter.expire(error)
        presenter.expire(hint)
        #expect(presenter.visible(error) == error)
        // Once the save works again, nothing shows.
        presenter.changed()
        #expect(presenter.visible(EditorToast.current(message: nil, saveError: nil)) == nil)
    }
}
