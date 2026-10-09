import Foundation
import Testing
@testable import UXReviewKit

/// HS2-T32CZC: Submit Review's Change menu also offers the projects Hot Sheet knows.
struct HotSheetProjectsTests {
    @Test func parsesCheckoutRootsWithoutTemporaryFoldersOrRepeats() {
        let json = """
        [{"id": "a-1", "root": "/Users/me/Code/app", "alias": "app", "stores": ["/Users/me/Code/app.hs2"]},
         {"id": "t-1", "root": "/private/tmp/hs2-singleton.X/code-a", "stores": []},
         {"id": "t-2", "root": "/tmp/scratch"},
         {"id": "v-1", "root": "/var/folders/h5/T/x"},
         {"id": "a-2", "root": "/Users/me/Code/app/"},
         {"id": "s-1", "root": "/Users/me/Code/site", "repository": "git@example.com:me/site.git"},
         {"id": "n-1"}, {"id": "r-1", "root": "relative/path"}]
        """
        #expect(HotSheetProjects.parse(json) == ["/Users/me/Code/app", "/Users/me/Code/site"])
        #expect(HotSheetProjects.parse("not json").isEmpty)
        #expect(HotSheetProjects.parse("{}").isEmpty)
        #expect(HotSheetProjects.parse("[]").isEmpty)
    }

    @Test func runsCheckoutListAndFallsBackToNoneOnFailure() {
        final class Runner: ProcessRunning, @unchecked Sendable {
            var result: ProcessResult
            var arguments: [String] = []
            init(_ result: ProcessResult) { self.result = result }
            func run(
                executable _: URL,
                arguments: [String],
                environment: [String: String],
                currentDirectory _: URL?
            ) throws -> ProcessResult {
                self.arguments = arguments
                #expect(environment["HOTSHEET_ACTOR_ROLE"] == nil)
                return result
            }
        }
        let working = Runner(ProcessResult(exitCode: 0, stdout: #"[{"root": "/Users/me/Code/app"}]"#, stderr: ""))
        #expect(HotSheetProjects.list(cliPath: "/bin/hotsheet-cli", runner: working) == ["/Users/me/Code/app"])
        #expect(working.arguments == ["checkout", "list"])
        let old = Runner(ProcessResult(exitCode: 2, stdout: "", stderr: "error: unrecognized subcommand 'checkout'"))
        #expect(HotSheetProjects.list(cliPath: "/bin/hotsheet-cli", runner: old).isEmpty)
    }

    @Test func theMenuListsHotSheetProjectsAfterTheRecentOnesByName() {
        let exists: (String) -> Bool = { !$0.hasPrefix("/gone") }
        let recent = RecentProjects(paths: ["/code/site", "/code/app"])
        let menu = recent.menu(
            current: "/code/site",
            hotSheet: ["/work/zeta", "/code/app", "/gone/old", "/work/Alpha", "/work/zeta/", "/other/site"],
            isDirectory: exists, abbreviate: { $0 }
        )
        #expect(menu.map(\.path) == ["/code/site", "/code/app", "/work/Alpha", "/other/site", "/work/zeta"])
        #expect(menu.map(\.isFromHotSheet) == [false, false, true, true, true])
        #expect(menu.map(\.isCurrent) == [true, false, false, false, false])
        // Two "site" folders across both groups: both show their paths.
        #expect(menu.map(\.title) == ["/code/site", "app", "Alpha", "/other/site", "zeta"])
        // Hot Sheet's current project isn't repeated below.
        let noRecent = RecentProjects().menu(current: "/work/zeta", hotSheet: ["/work/zeta"], isDirectory: exists)
        #expect(noRecent.map(\.path) == ["/work/zeta"] && noRecent[0].isCurrent && !noRecent[0].isFromHotSheet)
    }
}
