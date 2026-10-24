import Foundation
import SystemConfiguration

public struct TargetUser: Sendable, Equatable {
    public let name: String
    public let uid: uid_t
    public let gid: gid_t
    public let home: URL

    public var applicationsDirectory: URL { home.appendingPathComponent("Applications", isDirectory: true) }

    public static func lookup(name: String) -> TargetUser? {
        guard let pw = getpwnam(name) else { return nil }
        return TargetUser(pw.pointee)
    }

    public static func lookup(uid: uid_t) -> TargetUser? {
        guard let pw = getpwuid(uid) else { return nil }
        return TargetUser(pw.pointee)
    }

    /// For tests.
    init(name: String, uid: uid_t, gid: gid_t, home: URL) {
        self.name = name
        self.uid = uid
        self.gid = gid
        self.home = home
    }

    private init(_ pw: passwd) {
        name = String(cString: pw.pw_name)
        uid = pw.pw_uid
        gid = pw.pw_gid
        home = URL(fileURLWithPath: String(cString: pw.pw_dir), isDirectory: true)
    }

    /// The user logged in at the console, ignoring the login window and setup accounts.
    public static func consoleUser() -> TargetUser? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
              !["", "loginwindow", "root"].contains(name), !name.hasPrefix("_") else { return nil }
        return lookup(name: name)
    }

    /// Accounts in the local directory that a person signs in to, including cached mobile
    /// accounts, sorted by name. Callers should still `validate()` each one.
    public static func localAccounts() throws -> [TargetUser] {
        let result = try Command.run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"])
        guard result.status == 0 else {
            throw DecantError(.noTargetUser, "Cannot list local users: \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return parseAccountList(result.stdoutString).compactMap { lookup(name: $0) }
    }

    /// Picks people's accounts out of `dscl . -list /Users UniqueID` output.
    static func parseAccountList(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let uid = Int64(fields[1]) else { return nil }
            let name = String(fields[0])
            return isRegularAccount(name: name, uid: uid) ? name : nil
        }.sorted()
    }

    /// macOS gives accounts created in System Settings UIDs from 501. Lower UIDs are system and
    /// service accounts; negative ones (nobody, nogroup) are placeholders.
    static func isRegularAccount(name: String, uid: Int64) -> Bool {
        uid >= 501 && uid < Int64(Int32.max) && !name.hasPrefix("_") && name != "nobody"
    }

    /// Rejects accounts it would make no sense (or be unsafe) to install into.
    public func validate() throws {
        if uid == 0 || name.hasPrefix("_") {
            throw DecantError(.noTargetUser, "Refusing to install for system account \(name)")
        }
        var st = stat()
        guard lstat(home.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw DecantError(.noTargetUser, "Home folder \(home.path) for \(name) does not exist")
        }
        guard st.st_uid == uid else {
            throw DecantError(.destinationConflict, "Home folder \(home.path) is not owned by \(name)")
        }
    }

    /// Permanently becomes `uid` (groups, GID and UID). Used by the helper process that touches
    /// a user's files on root's behalf. Fails unless the switch is complete and irreversible.
    public static func dropPrivileges(to uid: uid_t) throws {
        guard uid != 0, let user = lookup(uid: uid) else {
            throw DecantError(.notAuthorized, "Refusing to run as uid \(uid)")
        }
        if geteuid() == 0 {
            guard initgroups(user.name, Int32(bitPattern: user.gid)) == 0, setgid(user.gid) == 0, setuid(uid) == 0 else {
                throw DecantError(.notAuthorized, "Cannot switch to \(user.name): \(String(cString: strerror(errno)))")
            }
        }
        guard getuid() == uid, geteuid() == uid, setuid(0) != 0 else {
            throw DecantError(.notAuthorized, "Not running as \(user.name)")
        }
    }
}
