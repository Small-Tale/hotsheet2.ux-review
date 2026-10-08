/// Who has focus when the interactive target picker ends. The picker's overlays never activate
/// UX Review, so normally nothing needs to change. Spec: docs/04-capture.md §4.2.
public enum PickerFocus {
    /// The app (by PID) to re-activate when picking ends, or nil to leave focus where it is.
    ///
    /// - `previousPID`: the frontmost app when picking began, or nil when it was UX Review.
    /// - `frontmostPIDNow`: the frontmost app as picking ends.
    ///
    /// Focus goes back to the previous app only when UX Review took it during picking. If the
    /// reviewer switched to a third app meanwhile, that choice stands.
    public static func appToReactivate(previousPID: Int32?, frontmostPIDNow: Int32?, ownPID: Int32) -> Int32? {
        guard let previousPID, previousPID != ownPID, frontmostPIDNow == ownPID else { return nil }
        return previousPID
    }
}
