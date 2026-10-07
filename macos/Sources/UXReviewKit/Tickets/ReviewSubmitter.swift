import Foundation

public enum ReviewSubmissionError: Error, Equatable, Sendable {
    case invalidBundle([BundleIssue])
    case missingMedia(String)
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
        let issues = bundle.validate()
        guard issues.isEmpty else { throw ReviewSubmissionError.invalidBundle(issues) }

        let mediaFiles = bundle.media.map { mediaDirectory.appendingPathComponent($0.filename) }
        for file in mediaFiles where !FileManager.default.fileExists(atPath: file.path) {
            throw ReviewSubmissionError.missingMedia(file.lastPathComponent)
        }

        let composed = TicketComposer.compose(bundle)
        let bundleFile = mediaDirectory.appendingPathComponent(composed.bundleFilename)
        try ReviewBundle.makeEncoder().encode(bundle).write(to: bundleFile, options: .atomic)

        let slug = try client.createTicket(composed.ticket)
        try client.attach(
            files: mediaFiles + [bundleFile],
            to: slug,
            batchLabel: "UX review capture",
            purpose: "problem_evidence"
        )
        return slug
    }
}
