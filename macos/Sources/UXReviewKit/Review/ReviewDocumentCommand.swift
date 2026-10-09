import Foundation

/// Headless document commands (`HS2-BKWZ5N`, `HS2-0D87NR`; docs/07 §7.10):
/// - `UXReview --open-review PATH [--drafts-dir DIR]`: the review becomes current.
/// - `UXReview --save-review NAME|PATH --to PATH [--copy] [--replace] [--drafts-dir DIR]`: File ›
///   Save (moves it), or with `--copy` Save As… (writes a copy).
/// - `UXReview --duplicate-review NAME|PATH [--drafts-dir DIR]`: File › Duplicate.
public enum ReviewDocumentCommand: Equatable, Sendable {
    case open(review: String, draftsDirectory: URL?)
    case save(review: String, destination: String, copy: Bool, replace: Bool, draftsDirectory: URL?)
    case duplicate(review: String, draftsDirectory: URL?)

    public static let flags = ["--open-review", "--save-review", "--duplicate-review"]

    /// Nil when none of `flags` is present.
    public static func parse(_ arguments: [String]) throws -> ReviewDocumentCommand? {
        let values = ArgumentValues(arguments)
        let directory = try values.optional("--drafts-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        func required(_ flag: String) throws -> String {
            guard let value = try values.optional(flag), !value.isEmpty else { throw CommandLineError.missingValue(flag) }
            return value
        }
        let given = flags.filter(arguments.contains)
        guard let flag = given.first else { return nil }
        guard given.count == 1 else { throw CommandLineError.missing("only one of \(flags.joined(separator: ", "))") }
        switch flag {
        case "--open-review":
            return .open(review: try required(flag), draftsDirectory: directory)
        case "--save-review":
            return .save(
                review: try required(flag), destination: try required("--to"),
                copy: arguments.contains("--copy"), replace: arguments.contains("--replace"), draftsDirectory: directory
            )
        default:
            return .duplicate(review: try required(flag), draftsDirectory: directory)
        }
    }

    public var draftsDirectory: URL? {
        switch self {
        case let .open(_, directory), let .save(_, _, _, _, directory), let .duplicate(_, directory): directory
        }
    }

    /// The review the command acts on: a path when it contains a `/`, else a name in `root`
    /// (with or without `.uxreview`).
    public func review(in root: URL) -> URL {
        let review = switch self {
        case let .open(review, _), let .save(review, _, _, _, _), let .duplicate(review, _): review
        }
        return DraftsCommand.discard(draft: review, draftsDirectory: nil).target(in: root)
            ?? root.appendingPathComponent(review, isDirectory: true)
    }
}
