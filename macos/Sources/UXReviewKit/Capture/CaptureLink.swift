import Foundation

/// A `uxreview://capture?…` link (`HS2-CWTNY2`): a web page, a script, or another app starts a
/// capture already set up for its project. The reviewer still picks the region (or window) and
/// still submits; a link only prepares. Spec: docs/04-capture.md §4.13.
///
///     uxreview://capture?kind=video&project=/Users/me/kerf&ticket=HS-1A2B3C&context=Demo%20step%203
///
/// | Parameter | Values | Default |
/// | --- | --- | --- |
/// | `kind` | `screenshot` (or `image`), `video` (or `recording`) | `screenshot` |
/// | `target` | `region`, `window`, `screen` (or `display`) | `region` |
/// | `delay` | whole seconds, 0–60 | 0 |
/// | `narrate` | `on`/`off` (`1`/`0`, `true`/`false`, `yes`/`no`); videos only | the setting |
/// | `project` | the project folder: an absolute path or a `file://` URL | the selected project |
/// | `ticket` | an existing ticket to add the review to: a slug, ULID, or ticket link | a new ticket |
/// | `title` | the review's title | |
/// | `context` | text that starts the review's overall notes | |
/// | `review` | `new` or `current` | `new` when the link sets a project, ticket, title, or context; else `current` |
///
/// Every value is checked; an unknown or repeated parameter is an error, so a typo never
/// silently captures the wrong thing.
public struct CaptureLink: Equatable, Sendable {
    public static let scheme = "uxreview"
    public static let action = "capture"
    public static let maxTitleLength = 200
    public static let maxContextLength = 10000

    public enum ReviewChoice: String, Equatable, Sendable {
        /// A new, empty review (the one in progress stays as it is).
        case new
        /// The review in progress, as a capture from the menu bar would.
        case current
    }

    public var request: CaptureRequest
    /// Overrides the narration setting for this recording; nil keeps the setting.
    public var narrate: Bool?
    public var project: URL?
    /// The ticket reference as given (checked to hold a slug or ULID).
    public var ticket: String?
    public var title: String?
    public var context: String?
    public var review: ReviewChoice

    public init(
        request: CaptureRequest = CaptureRequest(), narrate: Bool? = nil, project: URL? = nil, ticket: String? = nil,
        title: String? = nil, context: String? = nil, review: ReviewChoice? = nil
    ) {
        self.request = request
        self.narrate = narrate
        self.project = project
        self.ticket = ticket
        self.title = title
        self.context = context
        self.review = review ?? (project != nil || ticket != nil || title != nil || context != nil ? .new : .current)
    }

    /// What the link presets for the review it captures into, kept in the draft's `launch.json`.
    public var launch: DraftLaunch {
        DraftLaunch(projectDirectory: project?.standardizedFileURL.path, ticket: ticket)
    }

    /// True for any `uxreview:` URL, valid or not (the app routes these here, not to media opening).
    public static func isLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    // MARK: Parsing

    public static func parse(_ url: URL) throws -> CaptureLink {
        guard isLink(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CaptureLinkError.notALink
        }
        // `uxreview://capture?…` names the action as the host; `uxreview:capture?…` as the path.
        let action = (components.host?.isEmpty == false ? components.host : components.path)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() ?? ""
        guard action == Self.action else { throw CaptureLinkError.unknownAction(action) }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            guard Parameter(rawValue: name) != nil else { throw CaptureLinkError.unknownParameter(item.name) }
            guard values[name] == nil else { throw CaptureLinkError.repeatedParameter(name) }
            values[name] = item.value ?? ""
        }
        func value(_ parameter: Parameter) -> String? { values[parameter.rawValue] }

        var request = CaptureRequest()
        if let kind = value(.kind) {
            request.kind = try choose(.kind, kind, ["screenshot": .screenshot, "image": .screenshot, "video": .video, "recording": .video])
        }
        if let target = value(.target) {
            request.target = try choose(.target, target, ["region": .region, "window": .window, "screen": .display, "display": .display])
        }
        if let delay = value(.delay) {
            guard let seconds = Int(delay), (0 ... CaptureRequest.maxDelaySeconds).contains(seconds) else {
                throw CaptureLinkError.invalidValue(Parameter.delay.rawValue, delay)
            }
            request.delaySeconds = seconds
        }
        var narrate: Bool?
        if let text = value(.narrate) {
            narrate = try choose(
                .narrate,
                text,
                ["on": true, "1": true, "true": true, "yes": true, "off": false, "0": false, "false": false, "no": false]
            )
            guard request.kind == .video else { throw CaptureLinkError.narrationNeedsVideo }
        }
        return try CaptureLink(
            request: request,
            narrate: narrate,
            project: value(.project).map(projectURL),
            ticket: value(.ticket).map(ticketReference),
            title: value(.title).map { try text(.title, $0, limit: maxTitleLength) },
            context: value(.context).map { try text(.context, $0, limit: maxContextLength) },
            review: value(.review).map { try choose(.review, $0, ["new": ReviewChoice.new, "current": .current]) }
        )
    }

    enum Parameter: String, CaseIterable {
        case kind, target, delay, narrate, project, ticket, title, context, review
    }

    private static func choose<T>(_ parameter: Parameter, _ text: String, _ options: [String: T]) throws -> T {
        guard let value = options[text.trimmingCharacters(in: .whitespaces).lowercased()] else {
            throw CaptureLinkError.invalidValue(parameter.rawValue, text)
        }
        return value
    }

    /// An absolute folder path, or a `file://` URL of one. Whether it holds a Hot Sheet store is
    /// checked when submitting, as for a project chosen in the app.
    private static func projectURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.isFileURL, url.path.hasPrefix("/") {
            return URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL
        }
        guard trimmed.hasPrefix("/") else { throw CaptureLinkError.invalidValue(Parameter.project.rawValue, text) }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
    }

    private static func ticketReference(_ text: String) throws -> String {
        guard text.count <= maxTitleLength, let reference = TicketReference.parse(text) else {
            throw CaptureLinkError.invalidValue(Parameter.ticket.rawValue, text)
        }
        return reference
    }

    private static func text(_ parameter: Parameter, _ text: String, limit: Int) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit else { throw CaptureLinkError.invalidValue(parameter.rawValue, text) }
        return trimmed
    }

    // MARK: Preparing the review

    /// Makes the review this link captures into current, with its presets: a new empty review
    /// (`review=new`), or the current one (created when there is none and the link presets
    /// something). The title replaces the review's; the context starts its overall notes (after
    /// any notes already there); the project and ticket go in `launch.json`. Returns the review,
    /// or nil for a bare link into the current review when there is none yet (the capture
    /// creates it, as from the menu bar).
    @discardableResult
    public func prepare(in store: ReviewDraftStore) throws -> ReviewDraft? {
        let presets = title != nil || context != nil || launch != DraftLaunch()
        var draft: ReviewDraft
        switch review {
        case .new:
            draft = try store.createEmptyDraft()
        case .current:
            if let current = try store.current() {
                draft = current
            } else if presets {
                draft = try store.createEmptyDraft()
            } else {
                return nil
            }
        }
        if title != nil || context != nil {
            let summary = [draft.bundle.summary, context].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n\n")
            draft = try store.setDetails(draft.directory, title: title ?? draft.bundle.title, summary: summary)
        }
        if launch != DraftLaunch() {
            try launch.merged(into: DraftLaunch.load(from: draft.directory)).save(to: draft.directory)
        }
        return draft
    }
}

public enum CaptureLinkError: Error, Equatable, CustomStringConvertible {
    case notALink
    case unknownAction(String)
    case unknownParameter(String)
    case repeatedParameter(String)
    case invalidValue(String, String)
    case narrationNeedsVideo

    public var code: String {
        switch self {
        case .notALink: "notALink"
        case .unknownAction: "unknownAction"
        case .unknownParameter: "unknownParameter"
        case .repeatedParameter: "repeatedParameter"
        case .invalidValue: "invalidValue"
        case .narrationNeedsVideo: "narrationNeedsVideo"
        }
    }

    public var description: String {
        switch self {
        case .notALink: "Not a uxreview: link."
        case let .unknownAction(action): "UX Review links start with uxreview://capture, not “\(action)”."
        case let .unknownParameter(name): "Unknown link parameter “\(name)”."
        case let .repeatedParameter(name): "The link gives “\(name)” more than once."
        case let .invalidValue(name, value): "“\(value)” isn't a valid \(name)."
        case .narrationNeedsVideo: "narrate only applies to kind=video."
        }
    }
}
