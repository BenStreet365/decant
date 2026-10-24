import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    /// The process was killed because it ran longer than the timeout.
    public let timedOut: Bool

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum Command {
    /// Runs an executable without a shell. stdin is /dev/null unless `input` is given, so a
    /// child process can never block waiting for an answer from the (non-existent) user.
    /// With `timeout`, the child is killed (SIGKILL) if it runs longer than that.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        input: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe?
        if input != nil {
            inPipe = Pipe()
            process.standardInput = inPipe
        } else {
            inPipe = nil
            process.standardInput = FileHandle.nullDevice
        }

        try process.run()

        // The watchdog and the stderr drain run on threads of their own, not dispatch queues.
        // Callers block here, and when enough of them do (Swift concurrency, parallel tests on a
        // machine with few CPUs) the shared pool has no thread left for queued work: the drain
        // never finishes and the timeout never fires.
        let killed = Flag()
        let exited = DispatchSemaphore(value: 0)
        if let timeout {
            let pid = process.processIdentifier
            // Stands down as soon as the child exits, before its PID can be reused.
            Thread {
                if exited.wait(timeout: .now() + timeout) == .timedOut {
                    killed.value = true
                    kill(pid, SIGKILL)
                }
            }.start()
        }

        if let inPipe, let input {
            // Ignore SIGPIPE-style failures if the child exits before reading everything.
            try? inPipe.fileHandleForWriting.write(contentsOf: input)
            try? inPipe.fileHandleForWriting.close()
        }

        // Drain stderr on another thread so a chatty child cannot deadlock on a full pipe.
        let errBox = DataBox()
        let drained = DispatchSemaphore(value: 0)
        Thread {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }.start()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        exited.signal()
        return CommandResult(status: process.terminationStatus, stdout: out, stderr: errBox.data, timedOut: killed.value)
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
