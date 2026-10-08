import Foundation

/// A short message over the editor's canvas instead of a status line (`HS2-KJCJWX`): the editor's
/// last message (crop and trim results and hints) fades after a few seconds; a save error stays
/// until saving works again. Routine saves show nothing. Spec: docs/06-annotation-editor.md §6.1.
public struct EditorToast: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case info
        case error
    }

    public var text: String
    public var kind: Kind

    public init(_ text: String, kind: Kind = .info) {
        self.text = text
        self.kind = kind
    }

    /// How long an info toast shows.
    public static let infoDuration: Duration = .seconds(4)

    /// How long it shows; nil when it stays until its cause clears.
    public var duration: Duration? { kind == .info ? Self.infoDuration : nil }

    /// What to show now: a save error wins over the editor's message; nothing when neither is set.
    public static func current(message: String?, saveError: String?) -> EditorToast? {
        if let saveError, !saveError.isEmpty { return EditorToast(saveError, kind: .error) }
        if let message, !message.isEmpty { return EditorToast(message) }
        return nil
    }
}

/// Which toast is on screen: the current one unless it has expired. A toast that changes, or
/// clears and comes back, shows again.
public struct ToastPresenter: Equatable, Sendable {
    public private(set) var expired: EditorToast?

    public init() {}

    /// The current toast changed (including to or from nothing).
    public mutating func changed() {
        expired = nil
    }

    /// `toast`'s time is up; an error never expires.
    public mutating func expire(_ toast: EditorToast) {
        if toast.duration != nil { expired = toast }
    }

    public func visible(_ current: EditorToast?) -> EditorToast? {
        current == expired ? nil : current
    }
}
