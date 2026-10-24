import Darwin
import Foundation

public struct InstallRequest: Sendable {
    public var diskImagePath: String
    public var userName: String?
    public var dryRun: Bool
    /// Only install an app signed by this Team ID (`--expect-team-id`).
    public var expectedTeamID: String?
    /// Only install an app with this bundle ID (`--expect-bundle-id`).
    public var expectedBundleID: String?
    /// Only install the app whose code directory hash is this. Decant.app passes the one its
    /// check found, so Install installs exactly what the user was shown.
    public var expectedCDHash: String?
    /// The user whose profile the configuration was loaded for. When `checksConfiguredUser` is
    /// set, the install is refused if the target turns out to be someone else, which can happen
    /// when the console user changes as the install starts.
    public var configuredFor: String?
    public var checksConfiguredUser = false

    public init(diskImagePath: String, userName: String? = nil, dryRun: Bool = false,
                expectedTeamID: String? = nil, expectedBundleID: String? = nil) {
        self.diskImagePath = diskImagePath
        self.userName = userName
        self.dryRun = dryRun
        self.expectedTeamID = expectedTeamID
        self.expectedBundleID = expectedBundleID
    }
}

public struct InstallReport: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case installed, updated, unchanged, wouldInstall, wouldUpdate, skipped, failed
    }

    public var action: Action
    public var exitCode: Int32
    public var message: String
    public var diskImage: String
    public var user: String?
    public var app: String?
    public var bundleIdentifier: String?
    public var version: String?
    public var previousVersion: String?
    public var destination: String?
    public var teamID: String?
    public var cdHash: String?

    /// One exit code for several reports: the first failure, else the first skip, else success.
    public static func combinedExitCode(_ reports: [InstallReport]) -> Int32 {
        let ok = ExitStatus.success.rawValue
        if let failed = reports.first(where: { $0.action == .failed && $0.exitCode != ok }) { return failed.exitCode }
        if let skipped = reports.first(where: { $0.exitCode != ok }) { return skipped.exitCode }
        return ok
    }
}

/// Installs the single app from a drag-and-drop disk image into the target user's ~/Applications.
public final class Installer {
    public let config: Configuration
    public let log: Log
    /// Injectable for tests; defaults to the real effective UID.
    public var effectiveUID: uid_t = geteuid()
    /// The decant binary, re-run as the target user to read and delete files in their home
    /// folder when running as root (hidden `_inspect-bundle` and `_remove` commands).
    public var helperExecutable: String?
    /// Off in tests, so test apps are not added to the Launch Services database.
    public var registersWithLaunchServices = true

    /// Limits on work done in the user's files, which the user can make slow or hang.
    static let inspectTimeout: TimeInterval = 300
    static let removeTimeout: TimeInterval = 300

    public init(config: Configuration, log: Log) {
        self.config = config
        self.log = log
    }

    var isRoot: Bool { effectiveUID == 0 }

    // MARK: User

    public func resolveUser(_ requested: String?) throws -> TargetUser {
        if requested != nil, !config.allowUserOption {
            throw DecantError(.notAuthorized, "--user is disabled; set AllowUserOption in the device profile to enable it")
        }
        let user: TargetUser
        if isRoot {
            if let requested {
                guard let found = TargetUser.lookup(name: requested) else {
                    throw DecantError(.noTargetUser, "No such user \(requested)")
                }
                user = found
            } else {
                guard let console = TargetUser.consoleUser() else {
                    throw DecantError(.noTargetUser, "Nobody is logged in at the console; pass --user or retry later")
                }
                user = console
            }
        } else {
            guard let me = TargetUser.lookup(uid: getuid()) else {
                throw DecantError(.noTargetUser, "Cannot look up the current user")
            }
            if let requested, requested != me.name {
                throw DecantError(.notAuthorized, "Only root can install for another user")
            }
            user = me
        }
        try user.validate()
        return user
    }

    // MARK: Install

    public func install(_ request: InstallRequest) -> InstallReport {
        var report = InstallReport(action: .failed, exitCode: ExitStatus.failure.rawValue, message: "",
                                   diskImage: request.diskImagePath)
        do {
            // The MDM runs as root; anyone else installs only if the profile allows it.
            guard isRoot || config.allowUserInstalls else {
                throw DecantError(.notAuthorized, Configuration.userInstallsDisabledMessage)
            }
            let user = try resolveUser(request.userName)
            report.user = user.name
            if request.checksConfiguredUser, request.configuredFor != user.name {
                throw DecantError(.noTargetUser,
                    "The target user changed to \(user.name) while starting (configuration was loaded for \(request.configuredFor ?? "nobody")); retry")
            }
            let dmgPath = try existingDiskImagePath(request.diskImagePath)

            let lock = try InstallLock(isRoot: isRoot)
            defer { lock.release() }

            log.info("Installing from \(dmgPath) for user \(user.name) (uid \(user.uid))")
            let (image, source) = try mountApp(dmgPath)
            defer { image.detach() }
            try installApp(source, for: user, request: request, report: &report)
        } catch {
            record(error, in: &report)
        }
        return report
    }

    /// Installs into the ~/Applications of every local account that has a home folder. Root only.
    /// The image is mounted once; each user's copy is staged, verified and installed separately
    /// with that user's configuration, so one user's failure does not stop the others.
    public func installForAllUsers(_ request: InstallRequest,
                                   configurationFor: (TargetUser) -> Configuration) -> [InstallReport] {
        var base = InstallReport(action: .failed, exitCode: ExitStatus.failure.rawValue, message: "",
                                 diskImage: request.diskImagePath)
        var reports: [InstallReport] = []
        do {
            guard isRoot else { throw DecantError(.notAuthorized, "--all-users may only be used by root") }
            let users = try TargetUser.localAccounts().filter { user in
                do {
                    try user.validate()
                    return true
                } catch {
                    log.info("Skipping \(user.name): \(error)")
                    return false
                }
            }
            guard !users.isEmpty else { throw DecantError(.noTargetUser, "No local user accounts with a home folder") }
            let dmgPath = try existingDiskImagePath(request.diskImagePath)

            let lock = try InstallLock(isRoot: isRoot)
            defer { lock.release() }

            log.info("Installing from \(dmgPath) for \(users.count) users: \(users.map(\.name).joined(separator: ", "))")
            let (image, source) = try mountApp(dmgPath)
            defer { image.detach() }

            for user in users {
                var report = base
                report.user = user.name
                let installer = Installer(config: configurationFor(user), log: log)
                installer.effectiveUID = effectiveUID
                installer.helperExecutable = helperExecutable
                installer.registersWithLaunchServices = registersWithLaunchServices
                log.info("User \(user.name) (uid \(user.uid))")
                do {
                    try installer.installApp(source, for: user, request: request, report: &report)
                } catch {
                    installer.record(error, in: &report)
                }
                reports.append(report)
            }
        } catch {
            record(error, in: &base)
            reports.append(base)
        }
        return reports
    }

    func record(_ error: Error, in report: inout InstallReport) {
        if let error = error as? DecantError {
            report.action = [.appRunning, .downgradeRefused, .noTargetUser, .busy].contains(error.status) ? .skipped : .failed
            report.exitCode = error.status.rawValue
            report.message = error.message
            if report.action == .skipped { log.warning(error.message) } else { log.error(error.message) }
        } else {
            report.action = .failed
            report.exitCode = ExitStatus.installFailed.rawValue
            report.message = error.localizedDescription
            log.error(error.localizedDescription)
        }
    }

    func existingDiskImagePath(_ path: String) throws -> String {
        let dmgPath = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dmgPath, isDirectory: &isDir), !isDir.boolValue else {
            throw DecantError(.diskImageError, "Disk image \(dmgPath) does not exist")
        }
        return dmgPath
    }

    /// Mounts the image and returns the one app on it. The caller must detach the image.
    func mountApp(_ dmgPath: String) throws -> (DiskImage, AppBundle) {
        try DiskImage.preflight(dmgPath, acceptLicense: config.acceptLicenseAgreements)
        let image = try DiskImage(attaching: dmgPath, log: log)
        do {
            let payload = try PayloadAnalyzer.analyze(volumes: image.volumes)
            if !payload.ignored.isEmpty { log.debug("Ignoring image items: \(payload.ignored.joined(separator: ", "))") }
            return (image, try AppBundle(url: payload.app))
        } catch {
            image.detach()
            throw error
        }
    }

    /// `image` is the app on the mounted image. Everything after the signature check uses what
    /// the verified, staged copy says about itself instead.
    func installApp(_ image: AppBundle, for user: TargetUser, request: InstallRequest, report: inout InstallReport) throws {
        describe(image, in: &report)
        log.info("Found \(image.name) \(image.displayVersion) [\(image.bundleIdentifier)]")
        try checkBundleID(image, expected: request.expectedBundleID)

        let applications = try prepareApplicationsDirectory(for: user, makeChanges: !request.dryRun)
        let destination = applications.appendingPathComponent(image.name, isDirectory: true)
        report.destination = destination.path

        // Stage into a private, root-controlled directory on the destination volume and do all
        // verification on the staged copy, so what is verified is exactly what gets installed.
        let staging = try makeStagingDirectory(near: applications)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(image.name, isDirectory: true)
        try copy(image.url, to: staged)

        let signing = try CodeSignature.inspect(staged)
        report.teamID = signing.teamID
        report.cdHash = signing.cdHash
        log.info("Signature valid: team \(signing.teamID ?? signing.unverifiedTeamID.map { "\($0) (not verified by Apple)" } ?? "none"), identifier \(signing.signingID ?? "none"), cdhash \(signing.cdHash ?? "none")")
        if signing.isAdHoc, !config.allowAdHocSignatures {
            throw DecantError(.invalidSignature, "\(image.name) is only ad-hoc signed; set AllowAdHocSignatures to accept it")
        }
        // Info.plist is sealed by the signature, so from here on use the staged copy's.
        let source = try AppBundle(url: staged)
        describe(source, in: &report)
        try checkBundleID(source, expected: request.expectedBundleID)
        if let expected = request.expectedCDHash, signing.cdHash?.caseInsensitiveCompare(expected) != .orderedSame {
            throw DecantError(.bundleIDMismatch, "\(source.name) is not the copy that was checked (cdhash \(signing.cdHash ?? "none"), expected \(expected))")
        }

        try checkTeamAllowList(signing, expected: request.expectedTeamID)
        try checkGatekeeper(staged)

        // Only now look at the existing copy, so its claims are judged against a verified new one.
        let existing = try existingInstall(at: destination, for: user, source: source, signing: signing)
        if let existing {
            report.previousVersion = existing.inspection.displayVersion
            if existing.trust == .genuine {
                let previous = existing.inspection
                switch AppBundle.compareVersions(short: (source.shortVersion, previous.shortVersion),
                                                 build: (source.buildVersion, previous.buildVersion)) {
                case .orderedAscending? where !config.allowDowngrade:
                    throw DecantError(.downgradeRefused,
                        "Installed \(previous.displayVersion) is newer than \(source.displayVersion); set AllowDowngrade to replace it")
                default: break
                }
                if previous.displayVersion == source.displayVersion, let cdHash = previous.signing?.cdHash, cdHash == signing.cdHash {
                    report.action = .unchanged
                    report.exitCode = ExitStatus.success.rawValue
                    report.message = "\(source.name) \(source.displayVersion) is already installed"
                    log.info(report.message)
                    return
                }
            }
        }

        if request.dryRun {
            report.action = existing == nil ? .wouldInstall : .wouldUpdate
            report.exitCode = ExitStatus.success.rawValue
            report.message = "Dry run: \(source.name) \(source.displayVersion) would be \(existing == nil ? "installed" : "updated") at \(destination.path)"
            log.info(report.message)
            return
        }

        if existing != nil { try handleRunningApp(at: destination) }
        try setOwnership(of: staged, to: user)
        try moveIntoPlace(staging: staging, applications: applications, name: source.name, user: user, replacing: existing != nil)
        registerWithLaunchServices(destination, user: user)

        report.action = existing == nil ? .installed : .updated
        report.exitCode = ExitStatus.success.rawValue
        report.message = existing == nil
            ? "Installed \(source.name) \(source.displayVersion) to \(destination.path)"
            : "Updated \(source.name) from \(existing!.inspection.displayVersion) to \(source.displayVersion) at \(destination.path)"
        log.info(report.message)
    }

    func describe(_ app: AppBundle, in report: inout InstallReport) {
        report.app = app.name
        report.bundleIdentifier = app.bundleIdentifier
        report.version = app.displayVersion
    }

    // MARK: Checks

    func checkBundleID(_ app: AppBundle, expected: String?) throws {
        if let expected, app.bundleIdentifier != expected {
            throw DecantError(.bundleIDMismatch, "\(app.name) has bundle ID \(app.bundleIdentifier), not the expected \(expected)")
        }
    }

    func checkTeamAllowList(_ signing: SigningInfo, expected: String? = nil) throws {
        let team = signing.teamID ?? ""
        if let expected, expected.caseInsensitiveCompare(team) != .orderedSame {
            throw DecantError(.teamNotAllowed, "Team ID \(team.isEmpty ? "none" : team) is not the expected \(expected)")
        }
        guard !config.allowedTeamIdentifiers.isEmpty else { return }
        guard config.allowedTeamIdentifiers.contains(where: { $0.caseInsensitiveCompare(team) == .orderedSame }) else {
            throw DecantError(.teamNotAllowed, "Team ID \(team.isEmpty ? "none" : team) is not in AllowedTeamIdentifiers")
        }
    }

    func checkGatekeeper(_ app: URL) throws {
        guard config.requireGatekeeperAssessment else {
            log.info("Gatekeeper assessment is disabled by configuration")
            return
        }
        let result = try Command.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", app.path])
        let detail = (result.stderrString + result.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = Self.gatekeeperRejection(status: result.status, output: detail) {
            throw DecantError(.gatekeeperRejected, "Gatekeeper rejected \(app.lastPathComponent): \(reason)")
        }
        log.info("Gatekeeper accepted: \(detail.replacingOccurrences(of: "\n", with: "; "))")
    }

    /// Gatekeeper sources that mean Apple vouched for the app: notarised Developer ID, Apple's own
    /// code or the Mac App Store.
    static let trustedGatekeeperSources: Set<String> = ["Notarized Developer ID", "Apple System", "Mac App Store"]

    /// Returns why `spctl --assess` output is not proof of notarisation, or nil if it is. A zero
    /// exit status is not enough: with Gatekeeper disabled on the Mac, or a local `spctl --add`
    /// rule, spctl accepts anything ("override=security disabled", or the rule's label as source).
    static func gatekeeperRejection(status: Int32, output: String) -> String? {
        let flat = output.replacingOccurrences(of: "\n", with: "; ")
        guard status == 0 else { return flat }
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let override = lines.first(where: { $0.hasPrefix("override=") }) {
            return "assessment was not performed (\(override)); set RequireGatekeeperAssessment to false to install without it"
        }
        let source = lines.first(where: { $0.hasPrefix("source=") }).map { String($0.dropFirst("source=".count)) }
        guard let source, trustedGatekeeperSources.contains(source) else {
            return "source \(source ?? "unknown") is not notarised by Apple (\(flat))"
        }
        return nil
    }

    // MARK: Filesystem

    /// Ensures ~/Applications is a real directory owned by the user (never a symlink, since root
    /// writes into it), creating it if needed. With `makeChanges` false (dry run) nothing is touched.
    func prepareApplicationsDirectory(for user: TargetUser, makeChanges: Bool) throws -> URL {
        let dir = user.applicationsDirectory
        var st = stat()
        if lstat(dir.path, &st) != 0 {
            guard errno == ENOENT else {
                throw DecantError(.installFailed, "Cannot inspect \(dir.path): \(String(cString: strerror(errno)))")
            }
            guard makeChanges else { return dir }
            guard mkdir(dir.path, 0o755) == 0 || errno == EEXIST else {
                throw DecantError(.installFailed, "Cannot create \(dir.path): \(String(cString: strerror(errno)))")
            }
            if isRoot { _ = lchown(dir.path, user.uid, user.gid) }
            log.info("Created \(dir.path)")
            guard lstat(dir.path, &st) == 0 else {
                throw DecantError(.installFailed, "Cannot inspect \(dir.path)")
            }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw DecantError(.destinationConflict, "\(dir.path) is not a directory (symlinks are not followed)")
        }
        guard st.st_uid == user.uid || st.st_uid == 0 else {
            throw DecantError(.destinationConflict, "\(dir.path) is owned by uid \(st.st_uid), not \(user.name)")
        }
        if makeChanges, isRoot, st.st_uid != user.uid || st.st_mode & S_IRWXU != S_IRWXU {
            try repairOwnership(of: dir, for: user)
        }
        return dir
    }

    /// A root-owned ~/Applications (e.g. left by an older tool) stops the user removing or
    /// updating apps in it, so hand it back. Works through an O_NOFOLLOW descriptor so a symlink
    /// swapped in after the lstat cannot redirect the chown/chmod.
    func repairOwnership(of dir: URL, for user: TargetUser) throws {
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw DecantError(.destinationConflict, "Cannot open \(dir.path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == user.uid || st.st_uid == 0 else {
            throw DecantError(.destinationConflict, "\(dir.path) changed ownership during install")
        }
        guard fchown(fd, user.uid, user.gid) == 0, fchmod(fd, (st.st_mode & 0o7777) | S_IRWXU) == 0 else {
            throw DecantError(.installFailed, "Cannot give \(dir.path) to \(user.name): \(String(cString: strerror(errno)))")
        }
        log.info("Made \(dir.path) owned and writable by \(user.name)")
    }

    struct ExistingInstall {
        let inspection: BundleInspection
        let trust: ExistingTrust
    }

    /// Returns what is installed at `destination`, if anything. Refuses to touch anything that is
    /// really a different app. A copy without a genuine signature from the same team is replaced
    /// whatever version it claims, so a user cannot pin an old version by editing its Info.plist.
    func existingInstall(at destination: URL, for user: TargetUser, source: AppBundle, signing: SigningInfo) throws -> ExistingInstall? {
        var st = stat()
        guard lstat(destination.path, &st) == 0 else { return nil }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw DecantError(.destinationConflict, "\(destination.path) exists but is not an app bundle (symlinks are not followed)")
        }
        let inspection = try inspectExisting(destination, as: user)
        let trust = ExistingTrust.assess(inspection, sourceBundleID: source.bundleIdentifier, sourceSigning: signing)
        switch trust {
        case .genuine:
            log.info("Existing install found: \(inspection.displayVersion)")
        case .untrusted(let reason):
            log.warning("Existing \(destination.lastPathComponent) is not a genuine copy (\(reason)); replacing it regardless of its version")
        case .conflict(let reason):
            throw DecantError(.destinationConflict, "\(destination.path) \(reason); not overwriting")
        }
        return ExistingInstall(inspection: inspection, trust: trust)
    }

    /// Reads the user's existing copy. As root this runs in a helper process that has switched to
    /// the user, with a time limit, so a booby-trapped bundle (a FIFO or /dev/zero in place of
    /// Info.plist, a symlink to a root-only file) cannot hang the install or reveal anything.
    func inspectExisting(_ app: URL, as user: TargetUser) throws -> BundleInspection {
        guard isRoot else { return BundleInspection.inspect(app) }
        let result = try runAsUser(user, ["_inspect-bundle", app.path], timeout: Self.inspectTimeout)
        guard !result.timedOut else {
            throw DecantError(.destinationConflict, "Inspecting \(app.path) took longer than \(Int(Self.inspectTimeout))s; not touching it")
        }
        guard result.status == 0, let inspection = try? JSONDecoder().decode(BundleInspection.self, from: result.stdout) else {
            throw DecantError(.installFailed, "Cannot inspect \(app.path) as \(user.name): \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return inspection
    }

    /// Runs this tool's hidden helper command as `user`. The helper drops privileges itself.
    func runAsUser(_ user: TargetUser, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        guard let helper = helperExecutable else {
            throw DecantError(.installFailed, "No helper executable to run as \(user.name)")
        }
        return try Command.run(helper, arguments + ["--uid", String(user.uid)], timeout: timeout)
    }

    func makeStagingDirectory(near applications: URL) throws -> URL {
        // itemReplacementDirectory gives a directory owned by the caller on the same volume, so the
        // final rename is atomic. As root it is root-owned and outside the user's control.
        let base = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: applications, create: true)
        var st = stat()
        guard lstat(base.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == effectiveUID else {
            throw DecantError(.installFailed, "Staging directory \(base.path) is not safe to use")
        }
        chmod(base.path, 0o700)
        // On another volume the staging directory can sit inside a .TemporaryItems folder the
        // user owns, who could then swap it out from under root between the checks and the move.
        if isRoot, let problem = PathSafety.problem(with: base.path) {
            rmdir(base.path) // Never a recursive delete in a folder the user controls.
            throw DecantError(.installFailed, "Staging directory \(base.path) is not safe to use: \(problem)")
        }
        return base
    }

    func copy(_ source: URL, to destination: URL) throws {
        // --noacl: vendor ACLs (e.g. "everyone deny delete") would stop the user updating or
        // removing their own copy.
        let result = try Command.run("/usr/bin/ditto", ["--noqtn", "--noacl", source.path, destination.path])
        guard result.status == 0 else {
            throw DecantError(.installFailed, "Copy failed: \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // ditto --noqtn does not remove quarantine the vendor's files already carry. The app is
        // verified (signature, Gatekeeper) before install, so strip it: otherwise the user
        // would get a "downloaded from the internet" prompt on first launch.
        removeQuarantine(destination)
    }

    func removeQuarantine(_ root: URL) {
        var paths = [root.path]
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            while let relative = enumerator.nextObject() as? String {
                paths.append(root.appendingPathComponent(relative).path)
            }
        }
        for path in paths {
            removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    func setOwnership(of app: URL, to user: TargetUser) throws {
        // Owner-writable so the user's own updater (e.g. Sparkle) can update it later. Nothing
        // group/world-writable (other users must not be able to change this user's app) and no
        // setuid/setgid bits. Modes are not part of the code signature. chmod -R does not follow
        // symlinks.
        let chmod = try Command.run("/bin/chmod", ["-R", "u+rwX,go-w,ug-s", app.path])
        guard chmod.status == 0 else {
            throw DecantError(.installFailed, "chmod failed: \(chmod.stderrString)")
        }
        guard isRoot else { return }
        let result = try Command.run("/usr/sbin/chown", ["-R", "-h", "\(user.uid):\(user.gid)", app.path])
        guard result.status == 0 else {
            throw DecantError(.installFailed, "chown failed: \(result.stderrString)")
        }
    }

    func handleRunningApp(at destination: URL) throws {
        let pids = RunningProcesses.pids(inside: destination)
        guard !pids.isEmpty else { return }
        let list = pids.map(String.init).joined(separator: ", ")
        switch config.runningAppBehavior {
        case .skip:
            throw DecantError(.appRunning, "\(destination.lastPathComponent) is running (pid \(list)); not updating. Retry later or set RunningAppBehavior")
        case .replace:
            log.warning("\(destination.lastPathComponent) is running (pid \(list)); replacing anyway")
        case .terminate:
            log.warning("Terminating \(destination.lastPathComponent) (pid \(list))")
            guard RunningProcesses.terminate(pids) else {
                throw DecantError(.appRunning, "Could not terminate \(destination.lastPathComponent)")
            }
        }
    }

    /// Atomically puts the staged app in place using directory file descriptors opened with
    /// O_NOFOLLOW, so a user cannot redirect root's write by swapping in symlinks.
    func moveIntoPlace(staging: URL, applications: URL, name: String, user: TargetUser, replacing: Bool) throws {
        let destFD = open(applications.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard destFD >= 0 else {
            throw DecantError(.destinationConflict, "Cannot open \(applications.path): \(String(cString: strerror(errno)))")
        }
        defer { close(destFD) }
        var st = stat()
        guard fstat(destFD, &st) == 0, st.st_uid == user.uid || st.st_uid == 0 else {
            throw DecantError(.destinationConflict, "\(applications.path) changed ownership during install")
        }

        let stageFD = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stageFD >= 0 else {
            throw DecantError(.installFailed, "Cannot open staging directory: \(String(cString: strerror(errno)))")
        }
        defer { close(stageFD) }

        // With RENAME_SWAP the previous version lands in the staging directory and is deleted
        // with it. RENAME_EXCL fails rather than overwrite anything that appeared meanwhile.
        let flags = replacing ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        if renameatx_np(stageFD, name, destFD, name, flags) != 0 {
            let err = errno
            if replacing, err == ENOENT {
                // The old copy vanished since we looked; install fresh.
                guard renameatx_np(stageFD, name, destFD, name, UInt32(RENAME_EXCL)) == 0 else {
                    throw DecantError(.installFailed, "Cannot move app into place: \(String(cString: strerror(errno)))")
                }
            } else if err == EEXIST {
                throw DecantError(.destinationConflict, "\(name) appeared in \(applications.path) during install; not overwriting")
            } else if replacing, err == EPERM {
                // App Management (TCC) protects signed app bundles, even ones the user owns.
                throw DecantError(.appManagementDenied,
                                  "macOS blocked replacing \(name). Allow the app that ran decant under Privacy & Security → App Management, or deploy an App Management (SystemPolicyAppBundles) privacy profile")
            } else {
                throw DecantError(.installFailed, "Cannot move app into place: \(String(cString: strerror(err)))")
            }
        }

        if replacing { removeOldCopy(stageFD: stageFD, destFD: destFD, applications: applications, name: name, user: user) }
    }

    /// The swap left the previous copy in staging. It belongs to the user, who may still hold a
    /// descriptor inside it and swap in symlinks while it is deleted, so root must not delete it.
    /// Move it back next to the new copy under a hidden name and delete it as the user.
    func removeOldCopy(stageFD: Int32, destFD: Int32, applications: URL, name: String, user: TargetUser) {
        let trashName = ".\(name).decant-old-\(UUID().uuidString)"
        guard renameatx_np(stageFD, name, destFD, trashName, UInt32(RENAME_EXCL)) == 0 else {
            if errno != ENOENT { log.warning("Cannot move the previous copy out of staging: \(String(cString: strerror(errno)))") }
            return
        }
        let trash = applications.appendingPathComponent(trashName)
        if isRoot {
            let result = try? runAsUser(user, ["_remove", trash.path], timeout: Self.removeTimeout)
            if result?.status == 0, result?.timedOut == false { return }
        } else if (try? FileManager.default.removeItem(at: trash)) != nil {
            return
        }
        log.warning("Could not delete the previous copy; it was left at \(trash.path)")
    }

    func registerWithLaunchServices(_ app: URL, user: TargetUser) {
        guard registersWithLaunchServices else { return }
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let result: CommandResult?
        if isRoot {
            // Register in the user's Launch Services database, not root's.
            result = try? Command.run("/bin/launchctl", ["asuser", String(user.uid), "/usr/bin/sudo", "-n", "-u", user.name, lsregister, "-f", app.path])
        } else {
            result = try? Command.run(lsregister, ["-f", app.path])
        }
        if result?.status != 0 { log.debug("lsregister did not succeed (non-fatal)") }
    }
}

/// Serialises installs so two MDM runs cannot race on the same destination.
final class InstallLock {
    private var fd: Int32

    /// Long enough for another install of a large app; short enough that one stuck run cannot
    /// block every later MDM install for good.
    static let timeout: TimeInterval = 1800

    static let rootPath = "/private/var/run/\(Configuration.domain).lock"

    init(isRoot: Bool, timeout: TimeInterval = InstallLock.timeout) throws {
        let path = isRoot ? Self.rootPath
                          : FileManager.default.temporaryDirectory.appendingPathComponent("\(Configuration.domain).lock").path
        fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw DecantError(.installFailed, "Cannot open lock file \(path): \(String(cString: strerror(errno)))")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            guard err == EWOULDBLOCK || err == EINTR else {
                close(fd)
                throw DecantError(.installFailed, "Cannot lock \(path): \(String(cString: strerror(err)))")
            }
            guard Date() < deadline else {
                close(fd)
                throw DecantError(.busy, "Another decant install has held \(path) for over \(Int(timeout))s; retry later")
            }
            usleep(500_000)
        }
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
