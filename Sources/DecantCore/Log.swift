import Foundation
import os

/// Writes to stderr, the unified log and (optionally) a log file that MDM log collection can pick up.
/// The file is kept under `maxFileSize` by dropping its oldest lines.
public final class Log: @unchecked Sendable {
    public enum Level: String, Sendable { case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR" }

    public static let defaultMaxFileSize = 10 * 1024 * 1024

    private let osLog = Logger(subsystem: Configuration.domain, category: "install")
    private let lock = NSLock()
    private var fileDescriptor: Int32 = -1
    public var verbose = false
    public var quiet = false
    /// When the file grows past this many bytes, only the newest half is kept.
    public var maxFileSize = Log.defaultMaxFileSize

    public init() {}

    deinit {
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }

    public func attachFile(at path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Trimming rewrites the file in place, so never follow a symlink or write to anything but a
        // regular file of our own. A hard link would pass for a regular file, and a user can
        // hard-link a root-owned file such as /etc/sudoers into a folder they can write to.
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid() else {
            close(fd)
            return
        }
        lock.withLock {
            if fileDescriptor >= 0 { close(fileDescriptor) }
            fileDescriptor = fd
            flock(fd, LOCK_EX)
            trimIfNeeded(fd)
            flock(fd, LOCK_UN)
        }
    }

    public func debug(_ message: String) { write(.debug, message) }
    public func info(_ message: String) { write(.info, message) }
    public func warning(_ message: String) { write(.warning, message) }
    public func error(_ message: String) { write(.error, message) }

    private func write(_ level: Level, _ message: String) {
        switch level {
        case .debug: osLog.debug("\(message, privacy: .public)")
        case .info: osLog.info("\(message, privacy: .public)")
        case .warning: osLog.warning("\(message, privacy: .public)")
        case .error: osLog.error("\(message, privacy: .public)")
        }

        // Messages carry names from disk images, so a newline in one must not start a fake line.
        let message = message.escapingControlCharacters
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [\(getpid())] \(level.rawValue) \(message)\n"
        lock.withLock {
            appendToFile(line)
            let showOnConsole = !quiet && (level != .debug || verbose)
            if showOnConsole {
                FileHandle.standardError.write(Data("\(level.rawValue) \(message)\n".utf8))
            }
        }
    }

    /// Caller holds `lock`. The file lock serialises writers and trimming across processes,
    /// such as an `--all-users` run and a separate single-user install.
    private func appendToFile(_ line: String) {
        let fd = fileDescriptor
        guard fd >= 0 else { return }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        lseek(fd, 0, SEEK_END)
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        trimIfNeeded(fd)
    }

    /// Caller holds the file lock. Keeps the newest half of `maxFileSize`, starting at a line boundary.
    private func trimIfNeeded(_ fd: Int32) {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > maxFileSize else { return }
        let size = Int(info.st_size)
        let keep = max(maxFileSize / 2, 0)
        var tail = [UInt8](repeating: 0, count: keep)
        let read = tail.withUnsafeMutableBytes { pread(fd, $0.baseAddress, keep, off_t(size - keep)) }
        guard read == keep else { return }
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail.removeSubrange(...newline)
        } else {
            tail.removeAll()
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let marker = "\(timestamp) [\(getpid())] INFO Log trimmed to stay under \(maxFileSize) bytes\n"
        let contents = Array(marker.utf8) + tail
        let written = contents.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard written == contents.count else { return }
        ftruncate(fd, off_t(contents.count))
    }
}

extension String {
    /// The string with control characters and line or paragraph separators written as escapes
    /// (`\n`, `\u{1B}`), so text from a disk image or a user's files stays on one line.
    public var escapingControlCharacters: String {
        guard unicodeScalars.contains(where: \.isLineBreakingOrControl) else { return self }
        var result = ""
        for scalar in unicodeScalars {
            guard scalar.isLineBreakingOrControl else {
                result.unicodeScalars.append(scalar)
                continue
            }
            switch scalar {
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            }
        }
        return result
    }

    /// Whether the string has characters that `escapingControlCharacters` would escape.
    public var containsControlCharacters: Bool {
        unicodeScalars.contains(where: \.isLineBreakingOrControl)
    }
}

extension Unicode.Scalar {
    var isLineBreakingOrControl: Bool {
        switch properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }
}
