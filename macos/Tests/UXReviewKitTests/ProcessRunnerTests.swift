import Foundation
import Testing
@testable import UXReviewKit

struct ProcessRunnerTests {
    private func shell(_ script: String, environment: [String: String] = [:], directory: URL? = nil) throws -> ProcessResult {
        try SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            environment: environment, currentDirectory: directory
        )
    }

    @Test func capturesBothPipesBeyondTheirCapacity() throws {
        // stderr first forces a concurrent drain before the child can write stdout.
        let result = try shell("/usr/bin/head -c 262144 /dev/zero >&2; /usr/bin/head -c 262144 /dev/zero; exit 7")
        #expect(result.exitCode == 7)
        #expect(result.stdout == String(repeating: "\0", count: 262_144))
        #expect(result.stderr == String(repeating: "\0", count: 262_144))
    }

    @Test func capturesEmptyAndInvalidUTF8Output() throws {
        #expect(try shell("exit 0") == ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        let result = try shell("printf '\\377ok'; printf 'err\\377' >&2")
        #expect(result.stdout == "\u{FFFD}ok")
        #expect(result.stderr == "err\u{FFFD}")
    }

    @Test func passesEnvironmentAndWorkingDirectory() throws {
        let directory = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try shell("printf '%s' \"$RUNNER_VALUE\"; /bin/pwd >&2", environment: ["RUNNER_VALUE": "a b"], directory: directory)
        #expect(result.stdout == "a b")
        #expect(
            URL(fileURLWithPath: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
                == directory.resolvingSymlinksInPath()
        )
    }

    @Test func launchFailureThrows() {
        #expect(throws: (any Error).self) {
            try SystemProcessRunner().run(
                executable: URL(fileURLWithPath: "/definitely/missing/uxreview-process"),
                arguments: [], environment: [:], currentDirectory: nil
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cooperativeCallersCannotStarvePipeReaders() async throws {
        // More callers than the cooperative pool can run; also exercise with
        // LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 for single-worker scheduling.
        let count = max(32, ProcessInfo.processInfo.activeProcessorCount * 2)
        try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            for _ in 0 ..< count {
                group.addTask {
                    try shell("printf output; printf diagnostic >&2")
                }
            }
            var finished = 0
            for try await result in group {
                #expect(result == ProcessResult(exitCode: 0, stdout: "output", stderr: "diagnostic"))
                finished += 1
            }
            #expect(finished == count)
        }
    }
}
