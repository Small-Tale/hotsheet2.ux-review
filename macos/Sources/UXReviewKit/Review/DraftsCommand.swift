import Foundation

/// `UXReview --drafts [--drafts-dir DIR]` (list every draft review as JSON) and
/// `UXReview --discard-draft NAME|PATH [--drafts-dir DIR]` (move one to the Trash).
/// Spec: docs/07-review-session.md §7.10.
public enum DraftsCommand: Equatable, Sendable {
    case list(draftsDirectory: URL?)
    /// `draft` is a folder name inside the drafts directory, or a path when it contains a `/`.
    case discard(draft: String, draftsDirectory: URL?)

    /// Returns nil when neither `--drafts` nor `--discard-draft` is present.
    public static func parse(_ arguments: [String]) throws -> DraftsCommand? {
        let values = ArgumentValues(arguments)
        let directory = try values.optional("--drafts-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if arguments.contains("--discard-draft") {
            guard let draft = try values.optional("--discard-draft"), !draft.isEmpty else {
                throw CommandLineError.missingValue("--discard-draft")
            }
            return .discard(draft: draft, draftsDirectory: directory)
        }
        return arguments.contains("--drafts") ? .list(draftsDirectory: directory) : nil
    }

    public var draftsDirectory: URL? {
        switch self {
        case let .list(directory), let .discard(_, directory): directory
        }
    }

    /// The folder `--discard-draft` names: a path as given (relative to the working directory),
    /// or a name inside `root`. The store decides whether it is a draft at all.
    public func target(in root: URL) -> URL? {
        guard case let .discard(draft, _) = self else { return nil }
        if draft.contains("/") { return URL(fileURLWithPath: draft, isDirectory: true) }
        return root.appendingPathComponent(draft, isDirectory: true)
    }
}
