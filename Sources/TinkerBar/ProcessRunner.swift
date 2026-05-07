import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum CommandRunner {
    static func run(_ executable: String, arguments: [String]) -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        let outputGroup = DispatchGroup()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        readOutput(from: stdoutPipe, into: stdoutBuffer, group: outputGroup)
        readOutput(from: stderrPipe, into: stderrBuffer, group: outputGroup)

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            outputGroup.wait()
            return CommandResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        outputGroup.wait()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutBuffer.data, encoding: .utf8) ?? "",
            stderr: String(data: stderrBuffer.data, encoding: .utf8) ?? ""
        )
    }

    private static func readOutput(from pipe: Pipe, into buffer: OutputBuffer, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            buffer.store(data)
            group.leave()
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func store(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }
}
