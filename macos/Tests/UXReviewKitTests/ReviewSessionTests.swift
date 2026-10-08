import Foundation
import Testing
@testable import UXReviewKit

/// The review session state machine (docs/07 §7.4): every phase × every event, then realistic
/// and adversarial sequences (empty, repeated submit, failure then retry, captures removed
/// mid-session, the target going away).
struct ReviewSessionTests {
    static let ready = HotSheetStatus(cliPath: "/bin/hotsheet-cli", projectDirectory: "/p", storePath: "/p.hs2")
    static let rect = Shape.rect(NormRect(x: 100, y: 100, width: 2000, height: 1000))

    static func bundle(media: [MediaItem] = [TestSupport.image("m1", filename: "capture-1.png")], title: String = "Checkout review")
        -> ReviewBundle {
        var bundle = TestSupport.bundle(media: media, annotations: media.map {
            Annotation(id: "a-\($0.id)", mediaId: $0.id, shape: rect, note: "note")
        })
        bundle.title = title
        return bundle
    }

    static func session(_ bundle: ReviewBundle = bundle(), target: HotSheetStatus = ready) -> ReviewSession {
        ReviewSession(directory: URL(fileURLWithPath: "/drafts/d1"), bundle: bundle, target: target)
    }

    static let submitted = SubmittedReview(
        ticket: CreatedTicket(slug: "HS-1"), title: "t", mediaCount: 1, annotationCount: 1,
        storePath: "/p.hs2", submittedAt: Date(timeIntervalSince1970: 0)
    )

    enum PhaseName: CaseIterable { case editing, creating, attaching, submitted, failed }
    enum Event: CaseIterable { case refresh, edit, setTarget, begin, advance, succeed, fail }

    static func session(in phase: PhaseName) -> ReviewSession {
        var session = session()
        switch phase {
        case .editing: break
        case .creating: session.beginSubmit()
        case .attaching:
            session.beginSubmit()
            session.advance(.attachingMedia)
        case .submitted:
            session.beginSubmit()
            session.finish(.success(submitted))
        case .failed:
            session.beginSubmit()
            session.finish(.failure(SubmissionFailure(message: "boom")))
        }
        return session
    }

    static func apply(_ event: Event, to session: inout ReviewSession) -> Bool {
        switch event {
        case .refresh: session.refresh(bundle(title: "ignored"), missingFiles: [])
        case .edit: session.edit(title: "New title")
        case .setTarget: session.setTarget(ready)
        case .begin: session.beginSubmit()
        case .advance: session.advance(.attachingMedia)
        case .succeed: session.finish(.success(submitted))
        case .fail: session.finish(.failure(SubmissionFailure(message: "x")))
        }
    }

    @Test func transitionMatrix() {
        let allowed: [PhaseName: Set<Event>] = [
            .editing: [.refresh, .edit, .setTarget, .begin],
            .creating: [.advance, .succeed, .fail],
            .attaching: [.advance, .succeed, .fail],
            .submitted: [],
            .failed: [.refresh, .edit, .setTarget, .begin],
        ]
        for phase in PhaseName.allCases {
            for event in Event.allCases {
                var session = Self.session(in: phase)
                let before = session
                let applied = Self.apply(event, to: &session)
                let expected = allowed[phase]?.contains(event) == true
                #expect(applied == expected, "\(phase) + \(event)")
                if !applied { #expect(session == before, "\(phase) + \(event) changed a rejected session") }
            }
        }
    }

    @Test func phasesAfterEachAcceptedEvent() {
        var session = Self.session()
        #expect(session.isEditable && !session.isSubmitting && session.canSubmit)
        session.beginSubmit()
        #expect(session.phase == .submitting(.creatingTicket) && !session.isEditable && !session.canSubmit)
        session.advance(.attachingMedia)
        #expect(session.phase == .submitting(.attachingMedia))
        session.finish(.failure(SubmissionFailure(message: "no disk", createdTicket: "HS-1")))
        #expect(session.phase == .failed(SubmissionFailure(message: "no disk", createdTicket: "HS-1")))
        #expect(session.isEditable && session.canSubmit)
        session.beginSubmit()
        session.finish(.success(Self.submitted))
        #expect(session.phase == .submitted(Self.submitted) && !session.isEditable && !session.canSubmit)
    }

    @Test func emptySessionCannotSubmitUntilACaptureArrives() {
        var session = Self.session(Self.bundle(media: []))
        #expect(session.issues == [.noCaptures])
        let ok1 = session.beginSubmit()
        #expect(!ok1)
        #expect(session.phase == .editing)
        session.refresh(Self.bundle(), missingFiles: [])
        #expect(session.issues.isEmpty)
        let ok2 = session.beginSubmit()
        #expect(ok2)
    }

    @Test func blankTitleBlocksAndRefreshKeepsTheTypedTitle() {
        var session = Self.session()
        session.edit(title: "  \n ")
        #expect(session.issues == [.blankTitle])
        let ok3 = session.beginSubmit()
        #expect(!ok3)
        session.edit(title: "Typed", summary: "Typed summary")
        // A capture arrives; the bundle on disk still has the old title.
        session.refresh(
            Self.bundle(media: [TestSupport.image("m1", filename: "capture-1.png"), TestSupport.image("m2", filename: "capture-2.png")]),
            missingFiles: []
        )
        #expect(session.bundle.title == "Typed")
        #expect(session.bundle.summary == "Typed summary")
        #expect(session.bundle.media.count == 2)
        #expect(session.annotationCount("m2") == 1)
    }

    @Test func repeatedSubmitIsIgnoredWhileSubmitting() {
        var session = Self.session()
        let ok4 = session.beginSubmit()
        #expect(ok4)
        session.advance(.attachingMedia)
        let ok5 = session.beginSubmit()
        #expect(!ok5)
        let ok6 = session.beginSubmit()
        #expect(!ok6)
        #expect(session.phase == .submitting(.attachingMedia))
    }

    @Test func failureThenEditThenRetrySucceedsAndIsTerminal() {
        var session = Self.session()
        session.beginSubmit()
        session.finish(.failure(SubmissionFailure(message: "hotsheet-cli new failed (exit 1).")))
        let ok7 = session.edit(title: "Fixed title")
        #expect(ok7)
        let ok8 = session.beginSubmit()
        #expect(ok8)
        let ok9 = session.finish(.success(Self.submitted))
        #expect(ok9)
        let ok10 = session.finish(.failure(SubmissionFailure(message: "late")))
        #expect(!ok10)
        let ok11 = session.edit(title: "after")
        #expect(!ok11)
        let ok12 = session.refresh(Self.bundle(media: []), missingFiles: [])
        #expect(!ok12)
        #expect(session.phase == .submitted(Self.submitted))
    }

    @Test func capturesRemovedMidSessionApplyOnlyWhenEditable() {
        var session = Self.session(Self.bundle(media: [
            TestSupport.image("m1", filename: "capture-1.png"), TestSupport.image("m2", filename: "capture-2.png"),
        ]))
        session.beginSubmit()
        // The draft changes on disk while the ticket is being created: ignored, so what is
        // shown is what is being filed.
        let ok13 = session.refresh(Self.bundle(media: []), missingFiles: [])
        #expect(!ok13)
        #expect(session.bundle.media.count == 2)
        session.finish(.failure(SubmissionFailure(message: "x")))
        let ok14 = session.refresh(Self.bundle(media: [TestSupport.image("m2", filename: "capture-2.png")]), missingFiles: [])
        #expect(ok14)
        #expect(session.bundle.media.map(\.id) == ["m2"])
        #expect(session.canSubmit)
        let ok15 = session.refresh(Self.bundle(media: []), missingFiles: [])
        #expect(ok15)
        #expect(session.issues == [.noCaptures])
        let ok16 = session.beginSubmit()
        #expect(!ok16)
    }

    @Test func missingFilesAndUnavailableTargetBlockSubmit() {
        var session = Self.session()
        session.refresh(Self.bundle(), missingFiles: ["capture-1.png"])
        #expect(session.issues == [.missingFile(mediaId: "m1", filename: "capture-1.png")])
        session.refresh(Self.bundle(), missingFiles: [])
        session.setTarget(HotSheetStatus(problem: "No project selected."))
        #expect(session.issues == [.hotSheet("No project selected.")])
        let ok17 = session.beginSubmit()
        #expect(!ok17)
        session.setTarget(Self.ready)
        let ok18 = session.beginSubmit()
        #expect(ok18)
        // The target can't change under a running submission.
        let ok19 = session.setTarget(HotSheetStatus(problem: "gone"))
        #expect(!ok19)
        #expect(session.target == Self.ready)
    }

    @Test func issuesComeInAStableOrderWithReadableMessagesAndMedia() throws {
        let image = TestSupport.image("m1", filename: "capture-1.png")
        var bundle = Self.bundle(media: [image, TestSupport.video("m2", filename: "capture-2.mov", durationMs: 1000)], title: "")
        bundle.annotations = [
            Annotation(id: "a1", mediaId: "m1", shape: .rect(NormRect(x: 9000, y: 0, width: 2000, height: 10)), note: ""),
            Annotation(id: "a2", mediaId: "m2", shape: Self.rect, note: "", timeRange: TimeRange(startMs: 0, endMs: 5000)),
            Annotation(id: "a3", mediaId: "gone", shape: Self.rect, note: ""),
            Annotation(id: "a4", mediaId: "m1", shape: .arrow(points: [NormPoint(x: 1, y: 1)]), note: ""),
            Annotation(id: "a5", mediaId: "m1", shape: Self.rect, note: "", timeRange: TimeRange(startMs: 0, endMs: 1)),
        ]
        let issues = SessionIssue.all(for: bundle, target: HotSheetStatus(problem: "No project selected.")) { $0.id != "m2" }
        #expect(issues == [
            .blankTitle,
            .missingFile(mediaId: "m2", filename: "capture-2.mov"),
            .bundle(.shapeOutOfBounds(annotationId: "a1")),
            .bundle(.timeRangeBeyondDuration(annotationId: "a2")),
            .bundle(.unknownMedia(annotationId: "a3", mediaId: "gone")),
            .bundle(.tooFewPoints(annotationId: "a4", minimum: 2)),
            .bundle(.timeRangeOnImage(annotationId: "a5")),
            .hotSheet("No project selected."),
        ])
        #expect(issues.map { $0.message(in: bundle) } == [
            "Give the review a title.",
            "capture-2.mov is missing from the draft folder. Remove it from the review.",
            "Annotation #1 lies outside its capture.",
            "Annotation #2 runs past the end of its video.",
            "Annotation #3 is on a capture that is no longer in the review.",
            "Annotation #4 needs at least 2 points.",
            "Annotation #5 has a time range, but its capture is a still image.",
            "No project selected.",
        ])
        #expect(issues.map { $0.mediaId(in: bundle) } == [nil, "m2", "m1", "m2", "gone", "m1", "m1", nil])
    }

    @Test func everyBundleIssueHasAMessage() {
        let bundle = Self.bundle()
        let all: [BundleIssue] = [
            .unsupportedSchema("v9"), .noMedia, .duplicateMediaId("m1"), .duplicateFilename("capture-1.png"),
            .invalidMediaSize(mediaId: "m1"), .duplicateAnnotationId("a"), .unknownMedia(annotationId: "zz", mediaId: "q"),
            .shapeOutOfBounds(annotationId: "a-m1"), .tooFewPoints(annotationId: "a-m1", minimum: 3),
            .invalidTimeRange(annotationId: "a-m1"), .timeRangeOnImage(annotationId: "a-m1"),
            .timeRangeBeyondDuration(annotationId: "a-m1"),
        ]
        let messages = all.map { SessionIssue.bundle($0).message(in: bundle) }
        #expect(Set(messages).count == all.count)
        #expect(messages.allSatisfy { $0.hasSuffix(".") && !$0.isEmpty })
        #expect(messages[6] == "Annotation zz is on a capture that is no longer in the review.")
        #expect(messages[9] == "Annotation #1 ends before it starts.")
        #expect(SessionIssue.bundle(.duplicateFilename("capture-1.png")).mediaId(in: bundle) == "m1")
        #expect(SessionIssue.bundle(.noMedia).message(in: bundle) == SessionIssue.noCaptures.message(in: bundle))
    }

    // MARK: Recent projects and the headless command

    /// HS2-D1T46P: Change lists recent projects first, the current one checked among them.
    @Test func changeMenuListsRecentProjectsWithTheCurrentOneChecked() {
        let recent = RecentProjects(paths: ["/code/app", "/code/site", "/gone/old", "/work/app"])
        let exists: (String) -> Bool = { !$0.hasPrefix("/gone") }
        let abbreviate: (String) -> String = { $0.replacingOccurrences(of: "/code", with: "~") }

        let menu = recent.menu(current: "/code/site/", isDirectory: exists, abbreviate: abbreviate)
        #expect(menu.map(\.path) == ["/code/app", "/code/site", "/work/app"])
        #expect(menu.map(\.isCurrent) == [false, true, false])
        // Two folders named "app": both show their path; the unique one shows its name.
        #expect(menu.map(\.title) == ["~/app", "site", "/work/app"])

        // A current project set elsewhere (Settings, --project) is listed first even if not recent.
        let other = recent.menu(current: "/elsewhere/tool", isDirectory: exists)
        #expect(other.first == ProjectMenuItem(path: "/elsewhere/tool", title: "tool", isCurrent: true))
        #expect(other.count == 4)
        // The current project stays listed even when its folder is gone, so the check mark shows it.
        #expect(recent.menu(current: "/gone/old", isDirectory: exists).map(\.path) == ["/code/app", "/code/site", "/gone/old", "/work/app"])

        #expect(RecentProjects().menu(current: nil).isEmpty)
        #expect(RecentProjects().menu(current: "/") == [ProjectMenuItem(path: "/", title: "/", isCurrent: true)])
    }

    @Test func recentProjectsAreDedupedCappedAndPersisted() throws {
        var recent = RecentProjects()
        for name in ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"] {
            recent.use("/p/\(name)")
        }
        recent.use("/p/c/")
        recent.use("  ")
        #expect(recent.paths == ["/p/c", "/p/k", "/p/j", "/p/i", "/p/h", "/p/g", "/p/f", "/p/e", "/p/d", "/p/b"])
        for name in ["k", "j", "i", "h", "g"] {
            recent.remove("/p/\(name)")
        }
        #expect(recent.paths == ["/p/c", "/p/f", "/p/e", "/p/d", "/p/b"])
        recent.remove("/p/e")
        #expect(recent.existing { $0 != "/p/f" } == ["/p/c", "/p/d", "/p/b"])

        let store = MemoryStore()
        #expect(RecentProjectsStore.load(from: store) == RecentProjects())
        try RecentProjectsStore.save(recent, to: store)
        #expect(RecentProjectsStore.load(from: store) == recent)
        store.set(Data("nope".utf8), forKey: RecentProjectsStore.key)
        #expect(RecentProjectsStore.load(from: store) == RecentProjects())
        // A hand-edited list is normalized and capped on load.
        let many = (1 ... 10).map { "\"/\($0)\"" }.joined(separator: ",")
        store.set(Data((#"{"paths":["/x/","/x","# + many + "]}").utf8), forKey: RecentProjectsStore.key)
        #expect(RecentProjectsStore.load(from: store).paths == ["/x"] + (1 ... 9).map { "/\($0)" })
    }

    @Test func submitCommandParsing() throws {
        #expect(try SubmitCommand.parse(["--status"]) == nil)
        #expect(try SubmitCommand.parse(["--submit"]) == SubmitCommand())
        #expect(try SubmitCommand.parse([
            "--submit", "--drafts-dir", "/d", "--draft", "20261007-x", "--title", "T", "--summary", "S", "--project", "/p",
        ]) == SubmitCommand(draftsDirectory: URL(fileURLWithPath: "/d", isDirectory: true), draft: "20261007-x", title: "T", summary: "S"))
        for bad in ["../x", ".hidden", "a/b"] {
            #expect(throws: CommandLineError.invalidValue("--draft", bad)) { try SubmitCommand.parse(["--submit", "--draft", bad]) }
        }
        #expect(throws: CommandLineError.missingValue("--title")) { try SubmitCommand.parse(["--submit", "--title"]) }
    }
}
