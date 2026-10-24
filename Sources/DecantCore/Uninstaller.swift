import Darwin
import Foundation

public struct UninstallReport: Codable, Sendable {
    public var exitCode: Int32 = ExitStatus.success.rawValue
    public var dryRun: Bool
    /// Paths removed, or that would be with `--dry-run`.
    public var removed: [String] = []
    /// What could not be removed or undone.
    public var problems: [String] = []
}

/// Removes decant from the Mac: the tool, Decant.app, its package receipt, logs, lock files and
/// each user's app settings, caches and login item. Root only.
public final class Uninstaller {
    public static let toolPath = "/usr/local/bin/decant"
    public static let appPath = "/Applications/Decant.app"
    public static let appBundleIdentifier = "uk.street365.decant.app"
    public static let systemLogPath = "/Library/Logs/decant.log"
    public static let packageIdentifier = Configuration.domain

    /// Per-user items, relative to the home folder. Removed by a helper running as the user.
    public static let userItems = [
        "Library/Logs/decant.log",
        "Library/Preferences/\(appBundleIdentifier).plist",
        "Library/Caches/\(appBundleIdentifier)",
        "Library/HTTPStorages/\(appBundleIdentifier)",
        "Library/Saved Application State/\(appBundleIdentifier).savedState",
    ]

    static let helperTimeout: TimeInterval = 120

    public let config: Configuration
    public let log: Log
    /// The decant binary, re-run as each user to clean up their files (hidden `_cleanup-user`).
    public var helperExecutable: String?
    public var effectiveUID: uid_t = geteuid()

    public init(config: Configuration, log: Log) {
        self.config = config
        self.log = log
    }

    public func uninstall(dryRun: Bool) -> UninstallReport {
        var report = UninstallReport(dryRun: dryRun)
        do {
            guard effectiveUID == 0 else { throw DecantError(.notAuthorized, "uninstall may only be used by root") }

            // Wait for any install to finish so nothing is half-copied when the tool goes.
            let lock = try InstallLock(isRoot: true)
            defer { lock.release() }

            let users = (try? TargetUser.localAccounts())?.filter { (try? $0.validate()) != nil } ?? []
            let app = URL(fileURLWithPath: Self.appPath)

            if !dryRun, exists(Self.appPath) {
                let pids = RunningProcesses.pids(inside: app)
                if !pids.isEmpty {
                    log.info("Quitting Decant (pid \(pids.map(String.init).joined(separator: ", ")))")
                    if !RunningProcesses.terminate(pids) { report.problems.append("Could not quit Decant") }
                }
                for user in users where Self.isLoggedIn(user) {
                    unregisterLoginItem(for: user, report: &report)
                }
            }

            for user in users {
                cleanUp(user, dryRun: dryRun, report: &report)
            }

            stopUpdateDaemon(dryRun: dryRun, report: &report)
            var systemItems = [Self.appPath, Self.toolPath, Updater.daemonPlistPath, UpdateService.plistPath, UpdateState.directory,
                               Self.systemLogPath, InstallLock.rootPath]
            // Only ever a log file decant wrote, never a folder.
            if let custom = config.logFilePath, !systemItems.contains(custom), isRegularFile(custom) { systemItems.append(custom) }
            for path in systemItems {
                remove(path, dryRun: dryRun, report: &report)
            }
            forgetReceipt(dryRun: dryRun, report: &report)
        } catch let error as DecantError {
            report.exitCode = error.status.rawValue
            report.problems.append(error.message)
            log.error(error.message)
            return report
        } catch {
            report.problems.append(error.localizedDescription)
            log.error(error.localizedDescription)
        }
        if !report.problems.isEmpty {
            report.exitCode = ExitStatus.uninstallIncomplete.rawValue
            report.problems.forEach { log.warning($0) }
        }
        return report
    }

    // MARK: Per user

    static func isLoggedIn(_ user: TargetUser) -> Bool {
        (try? Command.run("/bin/launchctl", ["print", "gui/\(user.uid)"], timeout: 10))?.status == 0
    }

    /// The login item belongs to the user's Background Task Management record, so only the app
    /// running as that user in their session can remove it.
    /// Also drops the app's settings from the user's preferences daemon, which would otherwise
    /// write its cached copy back after the file is deleted.
    func unregisterLoginItem(for user: TargetUser, report: inout UninstallReport) {
        func runInSession(_ command: [String]) -> Int32? {
            try? Command.run("/bin/launchctl", ["asuser", String(user.uid), "/usr/bin/sudo", "-n", "-u", user.name] + command,
                             timeout: Self.helperTimeout).status
        }
        if runInSession([Self.appPath + "/Contents/MacOS/Decant", "--unregister-login-item"]) != 0 {
            report.problems.append("Could not remove Decant's login item for \(user.name)")
        } else {
            log.info("Removed Decant's login item for \(user.name)")
        }
        // Fails when there is nothing to delete, which is fine.
        _ = runInSession(["/usr/bin/defaults", "delete", Self.appBundleIdentifier])
    }

    /// Removes the user's items as the user, so a symlink in their home cannot point root at
    /// anything else.
    func cleanUp(_ user: TargetUser, dryRun: Bool, report: inout UninstallReport) {
        if dryRun {
            for item in Self.userItems {
                let path = user.home.appendingPathComponent(item).path
                if exists(path) { report.removed.append(path) }
            }
            return
        }
        guard let helper = helperExecutable else {
            report.problems.append("No helper to clean up \(user.name)'s files")
            return
        }
        guard let result = try? Command.run(helper, ["_cleanup-user", "--uid", String(user.uid)], timeout: Self.helperTimeout),
              result.status == 0, !result.timedOut else {
            report.problems.append("Could not clean up \(user.name)'s files")
            return
        }
        let removed = result.stdoutString.split(separator: "\n").map(String.init)
        report.removed += removed
        removed.forEach { log.info("Removed \($0)") }
    }

    /// Runs in the helper, already switched to the user. Returns what it removed.
    public static func removeUserItems(home: URL, temporaryDirectory: URL?) throws -> [String] {
        var paths = userItems.map { home.appendingPathComponent($0).path }
        if let temporaryDirectory {
            paths.append(temporaryDirectory.appendingPathComponent("\(Configuration.domain).lock").path)
        }
        var removed: [String] = []
        for path in paths {
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            try FileManager.default.removeItem(atPath: path)
            removed.append(path)
        }
        return removed
    }

    /// The per-user temporary folder that non-root installs keep their lock in.
    public static func userTemporaryDirectory() -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: System

    func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    func remove(_ path: String, dryRun: Bool, report: inout UninstallReport) {
        guard exists(path) else { return }
        if dryRun {
            report.removed.append(path)
            return
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            report.removed.append(path)
            log.info("Removed \(path)")
        } catch {
            report.problems.append("Could not remove \(path): \(error.localizedDescription)")
        }
    }

    /// Unloads the update daemon and service so launchd stops running a tool that is about to go.
    func stopUpdateDaemon(dryRun: Bool, report: inout UninstallReport) {
        for label in [Updater.daemonLabel, UpdateService.label] {
            let service = "system/\(label)"
            guard !dryRun, (try? Command.run("/bin/launchctl", ["print", service], timeout: 10))?.status == 0 else { continue }
            if (try? Command.run("/bin/launchctl", ["bootout", service], timeout: 30))?.status == 0 {
                log.info("Stopped \(label)")
            } else {
                report.problems.append("Could not stop \(label)")
            }
        }
    }

    func forgetReceipt(dryRun: Bool, report: inout UninstallReport) {
        guard let info = try? Command.run("/usr/sbin/pkgutil", ["--pkg-info", Self.packageIdentifier]), info.status == 0 else { return }
        let name = "package receipt \(Self.packageIdentifier)"
        if dryRun {
            report.removed.append(name)
            return
        }
        let result = try? Command.run("/usr/sbin/pkgutil", ["--forget", Self.packageIdentifier])
        if result?.status == 0 {
            report.removed.append(name)
            log.info("Forgot \(name)")
        } else {
            report.problems.append("Could not forget \(name)")
        }
    }
}
