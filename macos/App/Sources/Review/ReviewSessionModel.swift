import AppKit
import Combine
import UXReviewKit

/// The session window's observable wrapper around `ReviewSession`: keeps it in step with the
/// draft on disk, saves the title and summary, removes captures, and runs the submission off
/// the main thread. Spec: docs/07-review-session.md.
@MainActor
final class ReviewSessionModel: ObservableObject {
    @Published private(set) var session: ReviewSession
    /// Bound to the text fields; saved into the draft shortly after typing stops.
    @Published var title: String {
        didSet { if title != oldValue { fieldsChanged() } }
    }

    @Published var summary: String {
        didSet { if summary != oldValue { fieldsChanged() } }
    }

    /// The existing-ticket field; each change re-parses it and looks the ticket up shortly after.
    @Published var ticketInput: String {
        didSet {
            guard ticketInput != oldValue else { return }
            session.editTicket(ticketInput)
            scheduleLookup()
        }
    }

    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var recentProjects: [String] = []
    /// A problem outside the submission itself (a failed removal, an unreadable draft).
    @Published private(set) var notice: String?

    let store: ReviewDraftStore
    /// Saves and closes an open editor on the draft before it is submitted (and deleted).
    var closeEditor: (URL) -> Void = { _ in }
    /// Where the Hot Sheet target comes from (the app settings; previews pass a fixed one).
    var statusProvider: () -> HotSheetStatus = AppSettings.currentStatus
    /// Looks a ticket up (off the main thread); previews and tests replace it.
    var ticketFinder: @Sendable (TicketQuery, String) -> Result<HotSheetTicket?, SubmissionFailure> = { query, cli in
        query.run(cliPath: cli)
    }

    private var saveTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    /// The lookup running now, so the same query isn't started twice.
    private var lookupInFlight: TicketQuery?
    private var subscriptions: Set<AnyCancellable> = []
    private var thumbnailKeys: [String: String] = [:]

    static let saveDelay: Duration = .milliseconds(500)
    static let lookupDelay: Duration = .milliseconds(300)

    var directory: URL { session.directory }

    init(draft: ReviewDraft, store: ReviewDraftStore, target: HotSheetStatus) {
        self.store = store
        session = ReviewSession(
            directory: draft.directory,
            bundle: draft.bundle,
            target: target,
            missingFiles: Self.missingFiles(in: draft)
        )
        title = draft.bundle.title
        summary = draft.bundle.summary
        ticketInput = ""
        // A review whose media already went to an existing ticket goes back to that ticket (§7.5).
        if let pending = store.pendingSubmission(in: draft.directory), pending.isForExistingTicket,
           pending.storePath == target.storePath {
            ticketInput = pending.ticket.slug
            session.setDestination(.existingTicket)
            session.editTicket(pending.ticket.slug)
        }
        recentProjects = AppSettings.recentProjects
        loadThumbnails()
        NotificationCenter.default.publisher(for: .reviewDraftChanged)
            .compactMap { $0.object as? URL }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                MainActor.assumeIsolated {
                    guard let self, url.standardizedFileURL == self.directory.standardizedFileURL else { return }
                    self.reload()
                }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .hotSheetProjectChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshTarget() } }
            .store(in: &subscriptions)
        scheduleLookup()
    }

    // MARK: Reading the draft

    /// Re-reads the draft (captures added, editor saves) and the Hot Sheet target.
    func reload() {
        guard session.isEditable else { return }
        do {
            let draft = try store.load(directory)
            session.refresh(draft.bundle, missingFiles: Self.missingFiles(in: draft))
            notice = nil
            loadThumbnails()
        } catch {
            notice = "Couldn't read this review: \(ReviewSubmitter.describe(error))"
        }
    }

    func refreshTarget() {
        recentProjects = AppSettings.recentProjects
        session.setTarget(statusProvider())
        scheduleLookup()
    }

    // MARK: Destination

    func setDestination(_ destination: ReviewDestination) {
        guard session.setDestination(destination) else { return }
        scheduleLookup()
    }

    /// Starts the lookup the session waits for, after a short pause so typing doesn't run
    /// `hotsheet-cli show` on every key. A result for a query the session no longer waits for
    /// is ignored by the session.
    private func scheduleLookup() {
        guard let query = session.pendingLookup, let cli = session.target.cliPath, query != lookupInFlight else { return }
        lookupTask?.cancel()
        lookupInFlight = query
        let find = ticketFinder
        lookupTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lookupDelay)
            guard !Task.isCancelled, let self else { return }
            guard session.pendingLookup == query else {
                // Typed past it meanwhile; a later edit back to it schedules it again.
                if lookupInFlight == query { lookupInFlight = nil }
                return
            }
            let result = await Task.detached { find(query, cli) }.value
            if lookupInFlight == query { lookupInFlight = nil }
            session.resolveLookup(query, result)
        }
    }

    /// Previews resolve the waiting lookup without running `hotsheet-cli`.
    func previewLookup(_ result: Result<HotSheetTicket?, SubmissionFailure>) {
        lookupTask?.cancel()
        lookupInFlight = nil
        if let query = session.pendingLookup { session.resolveLookup(query, result) }
    }

    private static func missingFiles(in draft: ReviewDraft) -> Set<String> {
        Set(draft.bundle.media.filter { !FileManager.default.fileExists(atPath: draft.mediaURL($0).path) }.map(\.filename))
    }

    private func loadThumbnails() {
        for item in session.bundle.media {
            // Re-render when the file changes size (a crop or trim in the editor).
            let key = "\(item.filename)|\(item.pixelWidth)x\(item.pixelHeight)|\(item.durationMs ?? 0)"
            guard thumbnailKeys[item.id] != key else { continue }
            thumbnailKeys[item.id] = key
            let url = directory.appendingPathComponent(item.filename)
            thumbnails[item.id] = MediaThumbnail.make(url, kind: item.kind)
                .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }

    /// Previews show thumbnails without files on disk.
    func setThumbnail(_ image: NSImage, for mediaId: String) {
        thumbnails[mediaId] = image
    }

    // MARK: Editing

    private func fieldsChanged() {
        guard session.edit(title: title, summary: summary) else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveFields()
        }
    }

    /// Saves the title and summary into the draft now.
    func saveFields() {
        saveTask?.cancel()
        guard session.isEditable else { return }
        do {
            try store.setDetails(directory, title: title, summary: summary)
        } catch {
            notice = "Couldn't save the title and summary: \(ReviewSubmitter.describe(error))"
        }
    }

    /// Removes a capture (its file and annotations) from the review. An open editor on the draft
    /// stays open and drops the capture when it hears about the change (docs/06 §6.7).
    func remove(mediaId: String) {
        guard session.isEditable else { return }
        do {
            try store.removeMedia(mediaId, from: directory)
            thumbnails[mediaId] = nil
            thumbnailKeys[mediaId] = nil
            NotificationCenter.default.post(name: .reviewDraftChanged, object: directory)
            reload()
        } catch {
            notice = "Couldn't remove the capture: \(ReviewSubmitter.describe(error))"
        }
    }

    func useProject(_ url: URL) {
        guard session.isEditable else { return }
        AppSettings.useProject(url)
        refreshTarget()
    }

    func chooseProject() {
        if let url = AppSettings.chooseProjectFolder() { useProject(url) }
    }

    // MARK: Submitting

    /// Files the review. Does nothing unless the session can submit; the fields, the capture
    /// list, and the project are frozen until it finishes.
    func submit() {
        refreshTarget()
        let target = session.target
        guard let cliPath = target.cliPath, let storePath = target.storePath, session.beginSubmit() else { return }
        saveTask?.cancel()
        closeEditor(directory)
        let submitter = DraftSubmitter(
            store: store,
            client: HotSheetCLIClient(executable: URL(fileURLWithPath: cliPath), storePath: URL(fileURLWithPath: storePath)),
            storePath: URL(fileURLWithPath: storePath)
        )
        let directory = directory
        let title = title
        let summary = summary
        let existing = session.existingTicket
        // Progress arrives on the submitting thread; steps after the result are ignored by the session.
        let advance: @Sendable (SubmitStep) -> Void = { [weak self] step in
            Task { @MainActor in self?.session.advance(step) }
        }
        Task { [weak self] in
            let result = await Task.detached { () -> Result<SubmittedReview, SubmissionFailure> in
                do throws(SubmissionFailure) {
                    return try .success(submitter.submit(directory, title: title, summary: summary, into: existing, progress: advance))
                } catch {
                    return .failure(error)
                }
            }.value
            self?.finish(result)
        }
    }

    /// Applies a submission result (also used by previews).
    func finish(_ result: Result<SubmittedReview, SubmissionFailure>) {
        guard session.finish(result) else { return }
        if case let .success(review) = result {
            AppSettings.rememberProject(target: review)
            NotificationCenter.default.post(name: .reviewDraftChanged, object: directory)
        } else {
            reload()
        }
    }

    /// Previews put the session into a given phase without touching Hot Sheet.
    func previewSubmitting(_ step: SubmitStep) {
        if session.beginSubmit() { session.advance(step) }
    }

    func copySlug() {
        guard case let .submitted(review) = session.phase else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(review.ticket.slug, forType: .string)
    }

    func showTicketFile() {
        guard case let .submitted(review) = session.phase, let file = review.ticket.file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
    }
}

extension AppSettings {
    /// After a successful submission, the project it went to joins the recent projects.
    static func rememberProject(target review: SubmittedReview) {
        if let project = projectDirectory { rememberProject(project.path) } else { rememberProject(review.storePath) }
    }
}
