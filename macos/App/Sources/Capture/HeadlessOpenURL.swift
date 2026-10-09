import AppKit
import UXReviewKit

/// `UXReview --open-url URL [--drafts-dir DIR]`: what a `uxreview://capture?…` link does, short
/// of the interactive capture (`HS2-CWTNY2`): parses the link, prepares its review (a new one,
/// or the current one, with its title, notes, project, and ticket), and prints the capture it
/// would start as JSON. A following `--capture` adds to that review and `--submit` files it to
/// the link's project and ticket. Used by scripts/app-e2e.sh. Exit codes: 0 prepared, 2 bad
/// arguments or an invalid link, 5 the review couldn't be written. Spec: docs/04-capture.md §4.13.
@MainActor
enum HeadlessOpenURL {
    struct Success: Encodable {
        var status = "prepared"
        var request: CaptureRequest
        var narrate: Bool?
        var review: String
        /// The review the capture goes into; nil when a bare link has no review to go into yet.
        var draftDirectory: String?
        var title: String?
        var summary: String?
        var launch: DraftLaunch?
    }

    static func run(arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--open-url"), index + 1 < arguments.count,
              let url = URL(string: arguments[index + 1])
        else { return fail("invalidArguments", "--open-url needs a link", code: 2) }
        let link: CaptureLink
        do {
            link = try CaptureLink.parse(url)
        } catch let error as CaptureLinkError {
            return fail(error.code, error.description, code: 2)
        } catch {
            return fail("invalidArguments", String(describing: error), code: 2)
        }
        let draftsDirectory = arguments.firstIndex(of: "--drafts-dir").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let store = ReviewDraftStore(
            root: draftsDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AppSettings
                .draftsDirectory()
        )
        do {
            let draft = try link.prepare(in: store)
            let launch = draft.map { DraftLaunch.load(from: $0.directory) }
            print(HeadlessCapture.json(Success(
                request: link.request, narrate: link.narrate, review: link.review.rawValue,
                draftDirectory: draft?.directory.path, title: draft?.bundle.title, summary: draft?.bundle.summary,
                launch: launch == DraftLaunch() ? nil : launch
            )))
            return 0
        } catch {
            return fail("failed", ReviewSubmitter.describe(error), code: 5)
        }
    }

    private static func fail(_ error: String, _ message: String, code: Int32) -> Int32 {
        print(HeadlessCapture.json(HeadlessCapture.Failure(error: error, message: message)))
        return code
    }
}
