import Darwin
import Foundation

public enum RunningProcesses {
    /// PIDs of processes whose executable lives inside `bundle` (main app, helpers, XPC services).
    public static func pids(inside bundle: URL) -> [pid_t] {
        let prefix = bundle.standardizedFileURL.path + "/"
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }

        var result: [pid_t] = []
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if path.hasPrefix(prefix) { result.append(pid) }
        }
        return result
    }

    /// SIGTERM, wait up to `timeout`, then SIGKILL whatever is left. Returns false if any survive.
    public static func terminate(_ pids: [pid_t], timeout: TimeInterval = 10) -> Bool {
        for pid in pids { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(timeout)
        var remaining = pids
        while !remaining.isEmpty, Date() < deadline {
            usleep(200_000)
            remaining = remaining.filter { kill($0, 0) == 0 }
        }
        for pid in remaining { kill(pid, SIGKILL) }
        usleep(500_000)
        return remaining.allSatisfy { kill($0, 0) != 0 }
    }
}
