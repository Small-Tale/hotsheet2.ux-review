import Foundation
import Testing
@testable import UXReviewKit

struct HotSheetCLIClientTests {
    private let cli = URL(fileURLWithPath: "/bin/hotsheet-cli")
    private let store = URL(fileURLWithPath: "/stores/demo.hs2")

    private func client(_ runner: FakeRunner, env: [String: String] = [:]) -> HotSheetCLIClient {
        HotSheetCLIClient(executable: cli, storePath: store, runner: runner, baseEnvironment: env)
    }

    @Test func createTicketBuildsBoundArgumentsAndParsesSlug() throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "Created HS-R58EY5 (./tickets/X5/01M4.md)\n", stderr: ""),
        ])
        let slug = try client(runner).createTicket(NewTicket(
            title: "-leading dash", details: "--details-like text", category: "task", tags: ["ux-review", "a"], upNext: true
        ))
        #expect(slug == "HS-R58EY5")
        #expect(runner.calls.first?.executable == cli)
        #expect(runner.calls.first?.arguments == [
            "-C", "/stores/demo.hs2", "new", "--actor-role=human", "--actor-id=ux-review",
            "--title=-leading dash", "--category=task", "--details=--details-like text",
            "--tag=ux-review", "--tag=a", "--up-next",
        ])
    }

    @Test func createTicketReportsTheTicketFileWhenPrinted() throws {
        let outputs = [
            ("onboarding text\nCreated HS-ZNNDZG (/s/my store.hs2/tickets/G8/01M4.md)\n", CreatedTicket(
                slug: "HS-ZNNDZG",
                file: "/s/my store.hs2/tickets/G8/01M4.md"
            )),
            ("Created HS-1\n", CreatedTicket(slug: "HS-1")),
            ("Created HS-2 ()\n", CreatedTicket(slug: "HS-2")),
        ]
        for (stdout, expected) in outputs {
            let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: stdout, stderr: "")])
            #expect(try client(runner).createTicketReportingFile(NewTicket(title: "t", details: "d")) == expected)
        }
        // Transports without a file fall back to the slug alone.
        #expect(try FakeHotSheetClient().createTicketReportingFile(NewTicket(title: "t", details: "d")) == CreatedTicket(slug: "HS-TEST01"))
    }

    @Test func inheritedAIActorEnvironmentIsScrubbed() throws {
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: "Created HS-1 (x)", stderr: "")])
        _ = try client(runner, env: ["HOTSHEET_ACTOR_ROLE": "ai", "HOTSHEET_ACTOR_ID": "bot", "PATH": "/bin"])
            .createTicket(NewTicket(title: "t", details: "d"))
        #expect(runner.calls.first?.environment == ["PATH": "/bin"])
    }

    @Test func actorWithoutIdOmitsActorIdFlag() throws {
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: "Created HS-1 (x)", stderr: "")])
        var client = client(runner)
        client.actor = HotSheetActor(role: .system)
        _ = try client.createTicket(NewTicket(title: "t", details: "d"))
        #expect(runner.calls.first?.arguments.contains("--actor-role=system") == true)
        #expect(runner.calls.first?.arguments.contains { $0.hasPrefix("--actor-id") } == false)
    }

    @Test func createTicketFailureSurfacesExitCodeAndStderr() {
        let runner = FakeRunner(results: [ProcessResult(exitCode: 2, stdout: "", stderr: "no store")])
        #expect(throws: HotSheetError.commandFailed(command: "new", exitCode: 2, stderr: "no store")) {
            try client(runner).createTicket(NewTicket(title: "t", details: "d"))
        }
    }

    @Test func unexpectedCreateOutputIsAnError() {
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: "Something else\n", stderr: "")])
        #expect(throws: HotSheetError.unexpectedOutput(command: "new", stdout: "Something else\n")) {
            try client(runner).createTicket(NewTicket(title: "t", details: "d"))
        }
    }

    @Test func attachPassesBatchOptionsAndEndsOptionsBeforeFiles() throws {
        let runner = FakeRunner(results: [])
        try client(runner).attach(
            files: [URL(fileURLWithPath: "/tmp/-odd.png"), URL(fileURLWithPath: "/tmp/review.json")],
            to: "HS-1", batchLabel: "UX review capture", purpose: "problem_evidence"
        )
        #expect(runner.calls.first?.arguments == [
            "-C", "/stores/demo.hs2", "attach", "--actor-role=human", "--actor-id=ux-review", "HS-1",
            "--batch-label=UX review capture", "--purpose=problem_evidence", "--", "/tmp/-odd.png", "/tmp/review.json",
        ])
    }

    @Test func attachWithNoFilesDoesNothing() throws {
        let runner = FakeRunner(results: [])
        try client(runner).attach(files: [], to: "HS-1", batchLabel: nil, purpose: nil)
        #expect(runner.calls.isEmpty)
    }
}

struct HotSheetLocatorTests {
    @Test func explicitCLIWinsOverPath() {
        let found = HotSheetLocator.findCLI(
            environment: ["HOTSHEET_CLI": "/custom/hs", "PATH": "/a"],
            isExecutable: { ["/custom/hs", "/a/hotsheet-cli"].contains($0) }
        )
        #expect(found?.path == "/custom/hs")
    }

    @Test func pathIsSearchedInOrderThenFallbacks() {
        #expect(HotSheetLocator.findCLI(
            environment: ["PATH": "/a:/b"], isExecutable: { $0 == "/b/hotsheet-cli" }
        )?.path == "/b/hotsheet-cli")
        #expect(HotSheetLocator.findCLI(
            environment: ["PATH": "/usr/bin", "HOME": "/Users/me"], isExecutable: { $0 == "/Users/me/.cargo/bin/hotsheet-cli" }
        )?.path == "/Users/me/.cargo/bin/hotsheet-cli")
        #expect(HotSheetLocator.findCLI(environment: ["HOTSHEET_CLI": "/missing"], isExecutable: { _ in false }) == nil)
    }

    private func makeStore(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url.appendingPathComponent("hotsheet-store.json"))
    }

    @Test func resolvesStoreItselfPointerWalkUpAndSibling() throws {
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // A directory that is itself a store.
        let direct = root.appendingPathComponent("direct")
        try makeStore(at: direct)
        #expect(try HotSheetLocator.resolveStore(for: direct, environment: [:]).path == direct.path)

        // A pointer file in an ancestor, found from a nested directory.
        let project = root.appendingPathComponent("project")
        let nested = project.appendingPathComponent("macos/Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let linked = root.appendingPathComponent("elsewhere/linked.hs2")
        try makeStore(at: linked)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".hotsheet2"), withIntermediateDirectories: true)
        try Data("\(linked.path)\n".utf8).write(to: project.appendingPathComponent(".hotsheet2/store"))
        #expect(try HotSheetLocator.resolveStore(for: nested, environment: [:]).path == linked.path)

        // A sibling `<checkout>.hs2` with no pointer.
        let checkout = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let sibling = root.appendingPathComponent("checkout.hs2")
        try makeStore(at: sibling)
        #expect(try HotSheetLocator.resolveStore(for: checkout.appendingPathComponent("sub"), environment: [:]).path == sibling.path)

        // $HOTSHEET_STORE overrides discovery, and must point at a real store.
        #expect(try HotSheetLocator.resolveStore(for: checkout, environment: ["HOTSHEET_STORE": direct.path]).path == direct.path)
        let bogus = root.appendingPathComponent("bogus")
        #expect(throws: HotSheetError.storeNotFound(bogus)) {
            try HotSheetLocator.resolveStore(for: checkout, environment: ["HOTSHEET_STORE": bogus.path])
        }
    }

    /// Regression: a URL-based ancestor walk never terminated for directory URLs (`/` → `/..`),
    /// growing without bound until the test helper used tens of gigabytes.
    @Test(.timeLimit(.minutes(1)))
    func walkFromDirectoryURLTerminatesAtRoot() throws {
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dirURL = URL(fileURLWithPath: root.path, isDirectory: true).appendingPathComponent("a/b/", isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        #expect(throws: HotSheetError.storeNotFound(dirURL)) {
            try HotSheetLocator.resolveStore(for: dirURL, environment: [:])
        }
        #expect(throws: HotSheetError.self) {
            try HotSheetLocator.resolveStore(for: URL(fileURLWithPath: "/", isDirectory: true), environment: [:])
        }
    }

    @Test func stalePointerAndMissingStoreFail() throws {
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("lonely")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".hotsheet2"), withIntermediateDirectories: true)
        try Data("/definitely/not/here".utf8).write(to: project.appendingPathComponent(".hotsheet2/store"))
        #expect(throws: HotSheetError.storeNotFound(project)) {
            try HotSheetLocator.resolveStore(for: project, environment: [:])
        }
    }
}
