import Foundation

public enum ReviewSubmissionError: Error, Equatable, Sendable {
    case invalidBundle([BundleIssue])
    case missingMedia(String)
    /// The ticket was created but attaching the media failed. Retrying with `existingTicket`
    /// set to this slug attaches to it instead of creating a duplicate ticket.
    case attachFailed(ticket: CreatedTicket, reason: String)
    /// Adding to an existing ticket: the media is attached (under `attached`, draft file name →
    /// stored name) but the note failed. Retrying with those names writes only the note.
    case noteFailed(ticket: CreatedTicket, attached: [String: String], reason: String)
}

/// The Hot Sheet writes of a submission, reported as they start: a new ticket is created, then
/// its media attached; a review added to an existing ticket attaches its media, then adds a note.
public enum SubmitStep: String, Codable, Equatable, Sendable {
    case creatingTicket
    case attachingMedia
    case addingNote
}

/// Files a validated review bundle in Hot Sheet: creates the intake ticket, then attaches the
/// captured media plus `review.json` as one durable batch so every file shares a batch id.
public struct ReviewSubmitter: Sendable {
    public var client: HotSheetClient

    public init(client: HotSheetClient) {
        self.client = client
    }

    /// - Parameter mediaDirectory: folder holding each `MediaItem.filename`. `review.json` is
    ///   written there too, so it must be writable.
    /// - Returns: the created ticket's slug.
    @discardableResult
    public func submit(_ bundle: ReviewBundle, mediaDirectory: URL) throws -> String {
        try file(bundle, mediaDirectory: mediaDirectory).slug
    }

    /// Like `submit`, reporting each step, and able to resume a submission whose ticket was
    /// already created (`existingTicket`): then only the attachments are written.
    /// - Throws: `ReviewSubmissionError.attachFailed` with the slug when the ticket exists but
    ///   the attach failed, so the caller can retry without creating a second ticket.
    public func file(
        _ bundle: ReviewBundle,
        mediaDirectory: URL,
        existingTicket: CreatedTicket? = nil,
        progress: (SubmitStep) -> Void = { _ in }
    ) throws -> CreatedTicket {
        let (composed, files) = try prepare(bundle, mediaDirectory: mediaDirectory)

        let ticket: CreatedTicket
        if let existingTicket {
            ticket = existingTicket
        } else {
            progress(.creatingTicket)
            ticket = try client.createTicketReportingFile(composed.ticket)
        }
        progress(.attachingMedia)
        do {
            try client.attach(files: files, to: ticket.slug, batchLabel: Self.batchLabel, purpose: Self.purpose)
        } catch {
            throw ReviewSubmissionError.attachFailed(ticket: ticket, reason: Self.describe(error))
        }
        return ticket
    }

    public static let batchLabel = "UX review capture"
    public static let purpose = "problem_evidence"

    /// Validates the bundle, checks every media file exists, and writes `review.json`. Nothing is
    /// written when a check fails.
    /// - Returns: the composed review and the files to attach as one batch (media, then `review.json`).
    func prepare(_ bundle: ReviewBundle, mediaDirectory: URL) throws -> (ComposedReview, [URL]) {
        let issues = bundle.validate()
        guard issues.isEmpty else { throw ReviewSubmissionError.invalidBundle(issues) }

        let mediaFiles = bundle.media.map { mediaDirectory.appendingPathComponent($0.filename) }
        for file in mediaFiles where !FileManager.default.fileExists(atPath: file.path) {
            throw ReviewSubmissionError.missingMedia(file.lastPathComponent)
        }

        let composed = TicketComposer.compose(bundle)
        let bundleFile = mediaDirectory.appendingPathComponent(composed.bundleFilename)
        try ReviewBundle.makeEncoder().encode(bundle).write(to: bundleFile, options: .atomic)
        return (composed, mediaFiles + [bundleFile])
    }

    /// Adds the review to a ticket that already exists (docs/03 §3.5): attaches the media plus
    /// `review.json` as one batch, then appends a note built by `TicketComposer.note`, which cites
    /// each file by the name Hot Sheet stored it under.
    /// - Parameter attached: the stored names (draft file name → stored name) of a batch an earlier
    ///   try already attached. Then only the note is written, so a retry never attaches twice.
    /// - Throws: `ReviewSubmissionError.noteFailed` with the stored names when the attach worked
    ///   but the note didn't, so the caller can retry the note alone.
    public func add(
        _ bundle: ReviewBundle,
        mediaDirectory: URL,
        to ticket: CreatedTicket,
        attached: [String: String]? = nil,
        progress: (SubmitStep) -> Void = { _ in }
    ) throws -> CreatedTicket {
        let (_, files) = try prepare(bundle, mediaDirectory: mediaDirectory)
        let storedNames: [String: String]
        if let attached {
            storedNames = attached
        } else {
            progress(.attachingMedia)
            let stored = try client.attachReportingNames(files: files, to: ticket.slug, batchLabel: Self.batchLabel, purpose: Self.purpose)
            storedNames = Dictionary(zip(files.map(\.lastPathComponent), stored), uniquingKeysWith: { first, _ in first })
        }
        progress(.addingNote)
        do {
            try client.addNote(TicketComposer.note(for: bundle, storedNames: storedNames.filter { $0.key != $0.value }), to: ticket.slug)
        } catch {
            throw ReviewSubmissionError.noteFailed(ticket: ticket, attached: storedNames, reason: Self.describe(error))
        }
        return ticket
    }

    /// A one-line, human-readable reason for a Hot Sheet or file error.
    public static func describe(_ error: Error) -> String {
        switch error {
        case let error as HotSheetError:
            switch error {
            case .cliNotFound:
                return "hotsheet-cli was not found."
            case let .storeNotFound(url):
                return "No Hot Sheet store was found for \(url.path)."
            case let .commandFailed(command, exitCode, stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "hotsheet-cli \(command) failed (exit \(exitCode))" + (detail.isEmpty ? "." : ": \(detail)")
            case let .unexpectedOutput(command, _):
                return "hotsheet-cli \(command) printed something unexpected."
            }
        case let error as ReviewSubmissionError:
            switch error {
            case .invalidBundle: return "The review has problems to fix first."
            case let .missingMedia(name): return "\(name) is missing from the review."
            case let .attachFailed(ticket, reason): return "\(ticket.slug) was created, but attaching the media failed: \(reason)"
            case let .noteFailed(ticket, _, reason):
                return "The media was attached to \(ticket.slug), but adding the review note failed: \(reason)"
            }
        case let error as CustomStringConvertible:
            return error.description
        default:
            return error.localizedDescription
        }
    }
}
