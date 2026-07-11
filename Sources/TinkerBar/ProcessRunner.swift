import Darwin
import Foundation

enum CommandTermination: Equatable, Sendable {
    case completed
    case timedOut
    case cancelled
}

struct CommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let termination: CommandTermination

    init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        termination: CommandTermination = .completed
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.termination = termination
    }
}

enum CommandRunner {
    private static let defaultTimeout: TimeInterval = 30
    private static let defaultOutputLimit = 64 * 1024
    private static let terminationGracePeriod: TimeInterval = 1

    static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout,
        outputLimit: Int = defaultOutputLimit
    ) -> CommandResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = OutputBuffer(limit: outputLimit)
        let stderrBuffer = OutputBuffer(limit: outputLimit)
        let outputGroup = DispatchGroup()

        readOutput(from: stdoutPipe, into: stdoutBuffer, group: outputGroup)
        readOutput(from: stderrPipe, into: stderrBuffer, group: outputGroup)

        let spawnResult = spawn(
            executable,
            arguments: arguments,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        guard case .success(let processID) = spawnResult else {
            drainOutput(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe, group: outputGroup)
            guard case .failure(let message) = spawnResult else {
                preconditionFailure("Unexpected command spawn result")
            }
            return CommandResult(
                exitCode: 1,
                stdout: "",
                stderr: message
            )
        }

        let waitResult = waitForExit(
            processID: processID,
            timeout: timeout
        )
        drainOutput(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe, group: outputGroup)

        let stderr = [
            String(decoding: stderrBuffer.data, as: UTF8.self),
            waitResult.error ?? "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

        return CommandResult(
            exitCode: waitResult.exitCode,
            stdout: String(decoding: stdoutBuffer.data, as: UTF8.self),
            stderr: stderr,
            termination: waitResult.termination
        )
    }

    private static func spawn(
        _ executable: String,
        arguments: [String],
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) -> SpawnResult {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?

        let fileActionsResult = posix_spawn_file_actions_init(&fileActions)
        guard fileActionsResult == 0 else {
            return .failure(errorMessage(code: fileActionsResult))
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            return .failure(errorMessage(code: attributesResult))
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let stdoutRead = stdoutPipe.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrRead = stderrPipe.fileHandleForReading.fileDescriptor
        let stderrWrite = stderrPipe.fileHandleForWriting.fileDescriptor

        let actionResults = [
            posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&fileActions, stdoutRead),
            posix_spawn_file_actions_addclose(&fileActions, stdoutWrite),
            posix_spawn_file_actions_addclose(&fileActions, stderrRead),
            posix_spawn_file_actions_addclose(&fileActions, stderrWrite),
        ]
        if let failure = actionResults.first(where: { $0 != 0 }) {
            return .failure(errorMessage(code: failure))
        }

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        let flagResult = posix_spawnattr_setflags(&attributes, flags)
        guard flagResult == 0 else {
            return .failure(errorMessage(code: flagResult))
        }

        let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
        guard groupResult == 0 else {
            return .failure(errorMessage(code: groupResult))
        }

        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var processID: pid_t = 0
        let spawnResult = withCStringArray([executable] + arguments) { argumentPointer in
            withCStringArray(environment) { environmentPointer in
                executable.withCString { executablePointer in
                    posix_spawn(
                        &processID,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentPointer,
                        environmentPointer
                    )
                }
            }
        }

        guard spawnResult == 0 else {
            return .failure(errorMessage(code: spawnResult))
        }

        return .success(processID)
    }

    private static func waitForExit(
        processID: pid_t,
        timeout: TimeInterval
    ) -> ProcessWaitResult {
        let boundedTimeout = min(max(timeout, 0), 365 * 24 * 60 * 60)
        let timeoutNanoseconds = UInt64(boundedTimeout * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        var waitStatus: Int32 = 0

        while true {
            let waitResult = waitpid(processID, &waitStatus, WNOHANG)
            if waitResult == processID {
                return ProcessWaitResult(
                    exitCode: exitCode(from: waitStatus),
                    termination: .completed,
                    error: nil
                )
            }

            if waitResult == -1, errno != EINTR {
                return ProcessWaitResult(
                    exitCode: 1,
                    termination: .completed,
                    error: "Could not wait for command: \(errorMessage(code: errno))"
                )
            }

            if Task.isCancelled {
                return terminateAndWait(
                    processID: processID,
                    termination: .cancelled
                )
            }

            if DispatchTime.now().uptimeNanoseconds >= deadline {
                return terminateAndWait(
                    processID: processID,
                    termination: .timedOut
                )
            }

            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private static func terminateAndWait(
        processID: pid_t,
        termination: CommandTermination
    ) -> ProcessWaitResult {
        let processFamily = ProcessFamily(rootProcessID: processID)
        processFamily.send(signal: SIGTERM)
        let deadline = Date().addingTimeInterval(terminationGracePeriod)
        var waitStatus: Int32 = 0
        var leaderWasReaped = false

        while Date() < deadline {
            if !leaderWasReaped {
                let waitResult = waitpid(processID, &waitStatus, WNOHANG)
                if waitResult == processID {
                    leaderWasReaped = true
                } else if waitResult == -1, errno != EINTR {
                    return ProcessWaitResult(
                        exitCode: 1,
                        termination: termination,
                        error: "Could not wait for stopped command: \(errorMessage(code: errno))"
                    )
                }
            }

            if !processFamily.exists {
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if processFamily.exists {
            processFamily.send(signal: SIGKILL)
        }

        if !leaderWasReaped {
            while waitpid(processID, &waitStatus, 0) == -1 {
                if errno != EINTR {
                    return ProcessWaitResult(
                        exitCode: 1,
                        termination: termination,
                        error: "Could not reap stopped command: \(errorMessage(code: errno))"
                    )
                }
            }
        }

        return ProcessWaitResult(
            exitCode: exitCode(from: waitStatus),
            termination: termination,
            error: nil
        )
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return (waitStatus >> 8) & 0xff
        }

        return 128 + signal
    }

    private static func errorMessage(code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func withCStringArray<ResultValue>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> ResultValue
    ) -> ResultValue {
        let pointers = strings.map { strdup($0) }
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }

        var optionalPointers = pointers + [nil]
        return optionalPointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func drainOutput(stdoutPipe: Pipe, stderrPipe: Pipe, group: DispatchGroup) {
        if group.wait(timeout: .now() + 1) == .timedOut {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            _ = group.wait(timeout: .now() + 1)
        }
    }

    private static func readOutput(from pipe: Pipe, into buffer: OutputBuffer, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }

            while true {
                do {
                    guard
                        let data = try pipe.fileHandleForReading.read(upToCount: 8 * 1024),
                        !data.isEmpty
                    else {
                        return
                    }

                    buffer.append(data)
                } catch {
                    return
                }
            }
        }
    }
}

private struct ProcessWaitResult {
    let exitCode: Int32
    let termination: CommandTermination
    let error: String?
}

private enum SpawnResult {
    case success(pid_t)
    case failure(String)
}

private struct ProcessFamily {
    private let processIDs: Set<pid_t>
    private let processGroupIDs: Set<pid_t>

    init(rootProcessID: pid_t) {
        // Timeout wrappers and remote tools may create nested process groups, so
        // capture the full tree before signalling any process in it.
        var discoveredProcessIDs: Set<pid_t> = [rootProcessID]
        var pendingProcessIDs = [rootProcessID]
        var nextIndex = 0

        while nextIndex < pendingProcessIDs.count {
            let parentProcessID = pendingProcessIDs[nextIndex]
            nextIndex += 1

            for childProcessID in Self.childProcessIDs(of: parentProcessID) {
                if discoveredProcessIDs.insert(childProcessID).inserted {
                    pendingProcessIDs.append(childProcessID)
                }
            }
        }

        processIDs = discoveredProcessIDs
        processGroupIDs = Set(discoveredProcessIDs.compactMap { processID in
            let processGroupID = Darwin.getpgid(processID)
            guard
                processGroupID > 0,
                processGroupID == rootProcessID || discoveredProcessIDs.contains(processGroupID)
            else {
                return nil
            }
            return processGroupID
        })
    }

    var exists: Bool {
        processGroupIDs.contains { processGroupID in
            Darwin.killpg(processGroupID, 0) == 0 || errno == EPERM
        } || processIDs.contains { processID in
            Darwin.kill(processID, 0) == 0 || errno == EPERM
        }
    }

    func send(signal: Int32) {
        for processGroupID in processGroupIDs {
            _ = Darwin.killpg(processGroupID, signal)
        }
        for processID in processIDs {
            _ = Darwin.kill(processID, signal)
        }
    }

    private static func childProcessIDs(of parentProcessID: pid_t) -> [pid_t] {
        var capacity = 16
        let maximumCapacity = 16_384

        while true {
            var processIDs = [pid_t](repeating: 0, count: capacity)
            let count = processIDs.withUnsafeMutableBytes { buffer in
                proc_listchildpids(
                    parentProcessID,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }

            guard count > 0 else {
                return []
            }
            if count < capacity || capacity == maximumCapacity {
                return Array(processIDs.prefix(Int(count))).filter { $0 > 0 }
            }
            capacity = min(capacity * 2, maximumCapacity)
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()

    init(limit: Int) {
        self.limit = max(limit, 0)
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        guard limit > 0 else { return }

        if data.count >= limit {
            storage = Data(data.suffix(limit))
            return
        }

        storage.append(data)
        if storage.count > limit {
            storage.removeFirst(storage.count - limit)
        }
    }
}
