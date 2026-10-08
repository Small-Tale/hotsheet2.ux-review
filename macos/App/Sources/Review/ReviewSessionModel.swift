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
    /// The existing ticket a half-finished submission went to: its retry sends the same part.
    @Published private(set) var lockedTicket: String?

    /// What is sent to the chosen ticket is fixed until its half-finished submission finishes.
    var selectionLocked: Bool { lockedTicket != nil && session.existingTicket?.slug == lockedTicket }
    /// The draft's crops and trims (`edits.json`), applied only when submitting.
    @Published private(set) var edits = DraftEdits()
    /// The reviewer's edited preambles for this review (`ticket-text.json`, §7.2.3).
    @Published private(set) var ticketText = DraftTicketText()

    /// Each capture as it will be filed: cropped and trimmed, hidden annotations left out, scaled
    /// for AI (§7.2).
    var preview: SubmissionPreview { SubmissionPreview(session.bundle, edits: edits, scale: scaleTarget) }

    /// Like `preview`, for only what will be sent (the chosen part for an existing ticket).
    var sentPreview: SubmissionPreview { SubmissionPreview(session.selectedBundle, edits: edits, scale: scaleTarget) }

    /// Settings › Downscale images and videos for AI.
    @Published private(set) var downscaleForAI: Bool
    /// The AI size detected for a store.
    @Published private(set) var resolvedScale: (store: String, target: MediaScaleTarget)?
    /// Detects the AI size for a store (off the main thread): cli, store. Previews pass their own.
    let scaleDetector: @Sendable (String, String) -> MediaScaleTarget

    private var scaleTask: Task<Void, Never>?
    @Published private(set) var recentProjects: [String] = []
    /// A problem outside the submission itself (a failed removal, an unreadable draft).
    @Published private(set) var notice: String?

    let store: ReviewDraftStore
    /// Saves and closes an open editor on the draft before it is submitted (and deleted).
    var closeEditor: (URL) -> Void = { _ in }
    /// Where the Hot Sheet target comes from (the app settings; previews pass a fixed one).
    var statusProvider: () -> HotSheetStatus = AppSettings.currentStatus
    /// Moves a ticket to Hot Sheet's Trash (off the main thread): slug, cli, store. Previews replace it.
    var ticketTrasher: @Sendable (String, String, String) -> String? = { slug, cli, store in
        do {
            try HotSheetCLIClient(executable: URL(fileURLWithPath: cli), storePath: URL(fileURLWithPath: store)).moveToTrash(slug)
            return nil
        } catch {
            return ReviewSubmitter.describe(error)
        }
    }

    /// The ticket a failed New ticket try left behind, after the review went to an existing one (§7.5).
    enum AbandonedTicket: Equatable {
        case offered(String)
        case moving(String)
        case moved(String)
        case failed(String, reason: String)
    }

    @Published private(set) var abandonedTicket: AbandonedTicket?
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

    init(
        draft: ReviewDraft, store: ReviewDraftStore, target: HotSheetStatus,
        scaleDetector: @escaping @Sendable (String, String) -> MediaScaleTarget = AppSettings.scaleTarget
    ) {
        self.store = store
        self.scaleDetector = scaleDetector
        session = ReviewSession(
            directory: draft.directory,
            bundle: draft.bundle,
            target: target,
            missingFiles: Self.missingFiles(in: draft)
        )
        title = draft.bundle.title
        summary = draft.bundle.summary
        ticketInput = ""
        downscaleForAI = AppSettings.downscaleForAI
        // A review whose media already went to an existing ticket goes back to that ticket (§7.5).
        if let pending = store.pendingSubmission(in: draft.directory), pending.isForExistingTicket,
           pending.storePath == target.storePath {
            ticketInput = pending.ticket.slug
            session.setDestination(.existingTicket)
            session.editTicket(pending.ticket.slug)
            // A retry sends the same part it started with (§7.2.2).
            if let selection = pending.selection { session.setSelection(selection) }
            lockedTicket = pending.ticket.slug
        }
        recentProjects = AppSettings.recentProjects
        edits = DraftEdits.load(from: draft.directory)
        ticketText = DraftTicketText.load(from: draft.directory)
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
        NotificationCenter.default.publisher(for: .captureSettingsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshScale() } }
            .store(in: &subscriptions)
        scheduleLookup()
        refreshScale()
    }

    // MARK: Reading the draft

    /// Re-reads the draft (captures added, editor saves) and the Hot Sheet target.
    func reload() {
        guard session.isEditable else { return }
        do {
            let draft = try store.load(directory)
            session.refresh(draft.bundle, missingFiles: Self.missingFiles(in: draft))
            edits = DraftEdits.load(from: directory)
            ticketText = DraftTicketText.load(from: directory)
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
        refreshScale()
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
        let filed = preview.media
        for item in session.bundle.media {
            // As filed: the crop's part of an image, a movie's frame at its trim start. Re-render
            // when the file, its crop, or its trim changes.
            let crop = filed[item.id]?.crop
            let startMs = filed[item.id]?.trim?.startMs ?? 0
            let key =
                "\(item.filename)|\(item.pixelWidth)x\(item.pixelHeight)|\(item.durationMs ?? 0)|\(String(describing: crop))|\(startMs)"
            guard thumbnailKeys[item.id] != key else { continue }
            thumbnailKeys[item.id] = key
            let url = directory.appendingPathComponent(item.filename)
            thumbnails[item.id] = MediaThumbnail.make(url, kind: item.kind, crop: crop, atMs: startMs)
                .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }

    /// Previews set crops and trims without the editor.
    func previewEdits(_ edits: DraftEdits) {
        self.edits = edits
        loadThumbnails()
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
        // The size the list shows; detected while submitting if it isn't known yet.
        let (downscale, detect) = (downscaleForAI, scaleDetector)
        let submitter = DraftSubmitter(
            store: store,
            client: HotSheetCLIClient(executable: URL(fileURLWithPath: cliPath), storePath: URL(fileURLWithPath: storePath)),
            storePath: URL(fileURLWithPath: storePath),
            scale: downscale ? scaleTarget : nil
        )
        let directory = directory
        let title = title
        let summary = summary
        let existing = session.existingTicket
        let selection = session.selection
        // Progress arrives on the submitting thread; steps after the result are ignored by the session.
        let advance: @Sendable (SubmitStep) -> Void = { [weak self] step in
            Task { @MainActor in self?.session.advance(step) }
        }
        Task { [weak self] in
            let result = await Task.detached { [submitter] () -> Result<SubmittedReview, SubmissionFailure> in
                var submitter = submitter
                if downscale, submitter.scale == nil { submitter.scale = detect(cliPath, storePath) }
                do throws(SubmissionFailure) {
                    return try .success(submitter.submit(
                        directory, title: title, summary: summary, into: existing, selection: selection, progress: advance
                    ))
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
            abandonedTicket = review.abandonedTicket.map(AbandonedTicket.offered)
            AppSettings.rememberProject(target: review)
            NotificationCenter.default.post(name: .reviewDraftChanged, object: directory)
        } else {
            if case let .failure(failure) = result, let slug = failure.attachedTo { lockedTicket = slug }
            reload()
        }
    }

    /// Previews put the session into a given phase without touching Hot Sheet.
    func previewSubmitting(_ step: SubmitStep) {
        if session.beginSubmit() { session.advance(step) }
    }

    /// Moves the left-behind ticket to Hot Sheet's Trash (after the view's confirmation).
    func trashAbandonedTicket() {
        guard case let .submitted(review) = session.phase, let slug = review.abandonedTicket,
              let cli = session.target.cliPath ?? statusProvider().cliPath
        else { return }
        switch abandonedTicket {
        case .offered, .failed: break
        default: return
        }
        abandonedTicket = .moving(slug)
        let trash = ticketTrasher
        let store = review.storePath
        Task { [weak self] in
            let failure = await Task.detached { trash(slug, cli, store) }.value
            self?.abandonedTicket = failure.map { .failed(slug, reason: $0) } ?? .moved(slug)
        }
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

// MARK: Downscaling for AI (docs/07 §7.5.1)

extension ReviewSessionModel {
    /// The AI size captures are filed at (§7.5.1): nil while Downscale for AI is off, or until
    /// the project's AI tool is known.
    var scaleTarget: MediaScaleTarget? {
        guard downscaleForAI, let resolvedScale, resolvedScale.store == session.target.storePath else { return nil }
        return resolvedScale.target
    }

    /// Re-reads Downscale for AI and, when it is on, detects the project's AI size in the
    /// background (`hotsheet-cli ai-settings`), so the capture list shows the filed size.
    func refreshScale() {
        downscaleForAI = AppSettings.downscaleForAI
        guard downscaleForAI, let cli = session.target.cliPath, let store = session.target.storePath,
              resolvedScale?.store != store
        else { return }
        scaleTask?.cancel()
        let detect = scaleDetector
        scaleTask = Task { [weak self] in
            let target = await Task.detached { detect(cli, store) }.value
            guard !Task.isCancelled, let self, session.target.storePath == store else { return }
            resolvedScale = (store, target)
        }
    }

    /// Previews show captures scaled for `target` without reading Settings or Hot Sheet.
    func previewScale(_ target: MediaScaleTarget?) {
        scaleTask?.cancel()
        downscaleForAI = target != nil
        resolvedScale = target.flatMap { target in session.target.storePath.map { ($0, target) } }
    }
}

/// What goes to an existing ticket (§7.2.2) and the Ticket section's preamble (§7.2.3).
extension ReviewSessionModel {
    /// Includes or leaves out a capture for an existing ticket (§7.2.2).
    func setIncluded(media id: String, _ included: Bool) {
        guard !selectionLocked else { return }
        var selection = session.selection
        selection.set(media: id, included: included)
        session.setSelection(selection)
    }

    /// Includes or leaves out one annotation for an existing ticket (§7.2.2).
    func setIncluded(_ annotation: Annotation, _ included: Bool) {
        guard !selectionLocked else { return }
        var selection = session.selection
        selection.set(annotation, included: included, in: session.bundle)
        session.setSelection(selection)
    }

    /// Includes everything again.
    func selectEverything() {
        guard !selectionLocked else { return }
        session.setSelection(ReviewSelection())
    }

    /// The preamble the chosen destination files with.
    var preambleMode: TicketPreamble.Mode { session.destination == .newTicket ? .newTicket : .existingTicket }

    /// The chosen destination's preamble template: the reviewer's edit, else the standard one.
    var preambleTemplate: String { ticketText.template(preambleMode) }

    /// The preamble as it will be filed, values filled in (from what is sent).
    var preambleText: String {
        TicketPreamble.text(preambleMode, for: session.selectedBundle, template: ticketText[preambleMode])
    }

    var preambleIsStandard: Bool { ticketText[preambleMode] == nil }

    /// Saves the chosen destination's preamble template; nil goes back to the standard text (§7.2.3).
    func setPreamble(_ template: String?) {
        guard session.isEditable else { return }
        do {
            ticketText = try store.setTicketText(template, for: preambleMode, in: directory)
        } catch {
            notice = "Couldn't save the ticket text: \(ReviewSubmitter.describe(error))"
        }
    }
}
