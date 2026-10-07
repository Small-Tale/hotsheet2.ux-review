import Foundation

/// Result of running an external process to completion.
public struct ProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Seam over `Process` so the Hot Sheet client can be unit-tested with a fake runner.
public protocol ProcessRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) throws -> ProcessResult
}

/// Written by exactly one background reader and read only after `DispatchGroup.wait()`.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Runs a real child process and captures its output.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain stderr concurrently with stdout so a child that fills either pipe cannot
        // deadlock against us; wait for the process only after both reach EOF.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        let errData = errBox.data
        process.waitUntilExit()
        // Lossy decoding is deliberate: a stray invalid byte must not hide the rest of the output.
        // swiftlint:disable optional_data_string_conversion
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
        // swiftlint:enable optional_data_string_conversion
    }
}
