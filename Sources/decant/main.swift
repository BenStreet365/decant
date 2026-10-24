import DecantCore
import Foundation

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"

let usage = """
decant \(version) - install drag-and-drop disk images into ~/Applications for MDM deployments

USAGE:
  decant install <image.dmg> [--user <name> | --all-users] [--expect-team-id <id>] [--expect-bundle-id <id>]
                     [--dry-run] [--json] [--verbose] [--quiet]
  decant check-app <path.app> [--json]
  decant show-config [--user <name>] [--json]
  decant uninstall [--dry-run] [--json]
  decant update [--check] [--latest] [--json]
  decant version

  The MDM runs `install` as root (e.g. an Intune shell script), which installs for the
  console user. --user picks another account, but only when AllowUserOption is enabled.
  --all-users (root only) installs into every local account's ~/Applications.
  Run without root, it installs for the current user only, unless AllowUserInstalls is off.
  Nothing is ever shown to the user.
  --expect-team-id / --expect-bundle-id refuse any app but the one you meant to deploy.

  `uninstall` (root only) removes decant and Decant.app with their logs, settings and login
  items. --dry-run lists what would be removed.

  `update` (root) is what the uk.street365.decant.update LaunchDaemon runs every hour: it
  installs the newest GitHub release once it is UpdateDeferralDays old and the Mac is idle,
  unless AutomaticUpdates is off. It installs the package without Decant.app if the app is not
  installed. --check (any user) only reports whether one is available.
  --latest installs the newest release now, without waiting for UpdateDeferralDays or for
  the Mac to be idle. As root it ignores AutomaticUpdates too. Any other user's request goes
  to the update service, which installs it unless a profile turns AutomaticUpdates off or
  sets UpdateDeferralDays. With --check, it reports what --latest would install.

  Configuration is read from managed preferences (PayloadType \(Configuration.domain)).
  Root may also pass --config <file.plist> for testing.

EXIT CODES:
   0 installed, updated, already current or dry run OK
   1 unexpected internal error
  10 not authorised (--user disabled by AllowUserOption, install without root while
     AllowUserInstalls is off, or --user for another user, --all-users or --config used without root)
  11 no console user or it changed (retry later), bad --user, or no accounts for --all-users
  20 disk image could not be read/mounted, or is already open elsewhere
  21 not a simple drag-and-drop image - nothing was done
  22 invalid or missing code signature, or ad-hoc signed
  23 rejected by Gatekeeper
  24 Team ID not in AllowedTeamIdentifiers or not --expect-team-id
  25 bundle ID not --expect-bundle-id
  40 app is running (RunningAppBehavior = Skip)
  41 newer version already installed
  42 destination occupied by something else
  43 another install held the lock too long (retry later)
  50 install failed
  51 uninstall could not remove everything
  52 update could not check for, download or install a new version
  64 usage error
"""

struct Arguments {
    var positional: [String] = []
    var user: String?
    var configFile: String?
    var expectedTeamID: String?
    var expectedBundleID: String?
    var uid: uid_t?
    var allUsers = false
    var checkOnly = false
    var latest = false
    var feed: String?
    var allowUnsigned = false
    var dryRun = false
    var json = false
    var verbose = false
    var quiet = false

    init(_ args: ArraySlice<String>) throws {
        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--user", "-u":
                guard let v = it.next() else { throw DecantError(.usage, "--user needs a value") }
                user = v
            case "--config":
                guard let v = it.next() else { throw DecantError(.usage, "--config needs a value") }
                configFile = v
            case "--expect-team-id":
                guard let v = it.next(), !v.isEmpty else { throw DecantError(.usage, "--expect-team-id needs a value") }
                expectedTeamID = v
            case "--expect-bundle-id":
                guard let v = it.next(), !v.isEmpty else { throw DecantError(.usage, "--expect-bundle-id needs a value") }
                expectedBundleID = v
            case "--uid":
                guard let v = it.next(), let n = uid_t(v) else { throw DecantError(.usage, "--uid needs a number") }
                uid = n
            case "--all-users": allUsers = true
            case "--check": checkOnly = true
            case "--latest": latest = true
            case "--feed":
                guard let v = it.next(), !v.isEmpty else { throw DecantError(.usage, "--feed needs a value") }
                feed = v
            case "--allow-unsigned": allowUnsigned = true
            case "--dry-run", "-n": dryRun = true
            case "--json": json = true
            case "--verbose", "-v": verbose = true
            case "--quiet", "-q": quiet = true
            case "--help", "-h": throw DecantError(.success, usage)
            default:
                if arg.hasPrefix("-") { throw DecantError(.usage, "Unknown option \(arg)") }
                positional.append(arg)
            }
        }
    }
}

func emitJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

func loadConfiguration(_ args: Arguments, log: Log, userHint: String?) throws -> Configuration {
    // A user-supplied config file could switch off signature or Gatekeeper checks, so only root may use one.
    if args.configFile != nil, geteuid() != 0 {
        throw DecantError(.notAuthorized, "--config may only be used by root")
    }
    let (config, warnings) = ConfigurationLoader().load(userName: userHint, overrideFile: args.configFile)
    warnings.forEach { log.warning($0) }
    return config
}

/// The hidden commands root uses to touch a user's files as that user (see `Installer.runAsUser`).
func runHelper(_ command: String, _ args: Arguments) throws -> Int32 {
    if command == "_cleanup-user" {
        guard args.positional.isEmpty, let uid = args.uid else { throw DecantError(.usage, "\(command) needs --uid") }
        try TargetUser.dropPrivileges(to: uid)
        guard let user = TargetUser.lookup(uid: uid) else { throw DecantError(.noTargetUser, "No user with uid \(uid)") }
        let removed = try Uninstaller.removeUserItems(home: user.home, temporaryDirectory: Uninstaller.userTemporaryDirectory())
        removed.forEach { print($0) }
        return ExitStatus.success.rawValue
    }
    guard args.positional.count == 1, let uid = args.uid else { throw DecantError(.usage, "\(command) needs a path and --uid") }
    try TargetUser.dropPrivileges(to: uid)
    let url = URL(fileURLWithPath: args.positional[0])
    if command == "_inspect-bundle" {
        emitJSON(BundleInspection.inspect(url))
    } else {
        try FileManager.default.removeItem(at: url)
    }
    return ExitStatus.success.rawValue
}

func makeInstaller(_ config: Configuration, log: Log) -> Installer {
    let installer = Installer(config: config, log: log)
    installer.helperExecutable = Bundle.main.executablePath
    return installer
}

func run() -> Int32 {
    let log = Log()
    let raw = CommandLine.arguments.dropFirst()
    guard let command = raw.first else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return ExitStatus.usage.rawValue
    }

    do {
        let args = try Arguments(raw.dropFirst())
        log.verbose = args.verbose
        log.quiet = args.quiet

        // Root runs this binary from the update daemon and MDM scripts. If a user can replace it,
        // or a folder above it (a user-owned /usr/local/bin, say), they can run code as root.
        if geteuid() == 0, !["version", "--version", "help", "--help", "-h"].contains(command) {
            guard let executable = Bundle.main.executablePath else {
                throw DecantError(.failure, "Cannot find the decant executable")
            }
            if let problem = PathSafety.problem(with: executable) {
                throw DecantError(.failure, "Refusing to run as root: \(problem), so a non-root user could replace \(executable)")
            }
        }

        switch command {
        case "_inspect-bundle", "_remove", "_cleanup-user":
            return try runHelper(command, args)

        case "install":
            guard args.positional.count == 1 else { throw DecantError(.usage, "install needs exactly one disk image path") }
            if args.allUsers {
                guard args.user == nil else { throw DecantError(.usage, "--user and --all-users cannot be combined") }
                guard geteuid() == 0 else { throw DecantError(.notAuthorized, "--all-users may only be used by root") }
                let config = try loadConfiguration(args, log: log, userHint: nil)
                log.attachFile(at: config.effectiveLogFilePath())
                let installer = makeInstaller(config, log: log)
                let request = InstallRequest(diskImagePath: args.positional[0], dryRun: args.dryRun,
                                             expectedTeamID: args.expectedTeamID, expectedBundleID: args.expectedBundleID)
                // Each user gets their own user-scoped profile on top of the device one.
                let reports = installer.installForAllUsers(request) { user in
                    (try? loadConfiguration(args, log: log, userHint: user.name)) ?? config
                }
                if args.json {
                    emitJSON(reports)
                } else if !args.quiet {
                    for report in reports {
                        print("RESULT \(report.action.rawValue) user=\(report.user ?? "-") exit=\(report.exitCode): \(report.message.escapingControlCharacters)")
                    }
                }
                return InstallReport.combinedExitCode(reports)
            }
            // The user is not known until after authorisation, so use the requested or console
            // user only for picking up a user-scoped profile.
            let hint = args.user ?? (geteuid() == 0 ? TargetUser.consoleUser()?.name : TargetUser.lookup(uid: getuid())?.name)
            let config = try loadConfiguration(args, log: log, userHint: hint)
            log.attachFile(at: config.effectiveLogFilePath())
            let installer = makeInstaller(config, log: log)
            var request = InstallRequest(diskImagePath: args.positional[0], userName: args.user, dryRun: args.dryRun,
                                         expectedTeamID: args.expectedTeamID, expectedBundleID: args.expectedBundleID)
            request.configuredFor = hint
            request.checksConfiguredUser = true
            let report = installer.install(request)
            // Details already went to stderr; stdout gets one machine-greppable result line.
            if args.json {
                emitJSON(report)
            } else if !args.quiet {
                print("RESULT \(report.action.rawValue) exit=\(report.exitCode): \(report.message.escapingControlCharacters)")
            }
            return report.exitCode

        case "check-app":
            guard args.positional.count == 1 else { throw DecantError(.usage, "check-app needs exactly one app path") }
            // AppBundle never follows symlinks inside the bundle; one to the bundle itself is fine here.
            let app = try AppBundle(url: URL(fileURLWithPath: args.positional[0]).resolvingSymlinksInPath())
            let signing = try CodeSignature.inspect(app.url)
            struct CheckResult: Encodable { let app: String; let bundleIdentifier: String; let version: String; let signing: SigningInfo }
            let result = CheckResult(app: app.url.path, bundleIdentifier: app.bundleIdentifier, version: app.displayVersion,
                                     signing: signing)
            if args.json {
                emitJSON(result)
            } else {
                print("""
                App:          \(result.app)
                Bundle ID:    \(result.bundleIdentifier)
                Version:      \(result.version)
                Team ID:      \(signing.teamID ?? signing.unverifiedTeamID.map { "\($0) (not verified by Apple)" } ?? "none")
                Signing ID:   \(signing.signingID ?? "none")
                CDHash:       \(signing.cdHash ?? "none")
                Signing:      \(signing.isAdHoc ? "ad-hoc" : signing.states.map(\.rawValue).sorted().joined(separator: ", "))
                """)
            }
            return ExitStatus.success.rawValue

        case "show-config":
            let config = try loadConfiguration(args, log: log, userHint: args.user)
            if args.json {
                emitJSON(config)
            } else {
                print("""
                Domain:                       \(Configuration.domain)
                Sources:                      \(config.sources.joined(separator: ", "))
                RequireGatekeeperAssessment:  \(config.requireGatekeeperAssessment)
                AllowAdHocSignatures:         \(config.allowAdHocSignatures)
                AllowedTeamIdentifiers:       \(config.allowedTeamIdentifiers.isEmpty ? "(any)" : config.allowedTeamIdentifiers.joined(separator: ", "))
                AcceptLicenseAgreements:      \(config.acceptLicenseAgreements)
                AllowDowngrade:               \(config.allowDowngrade)
                RunningAppBehavior:           \(config.runningAppBehavior.rawValue)
                AllowUserOption:              \(config.allowUserOption)
                AllowUserInstalls:            \(config.allowUserInstalls)
                ShowInMenuBar:                \(config.showInMenuBar.map(String.init) ?? "(user's choice)")
                OpenAtLogin:                  \(config.openAtLogin.map(String.init) ?? "(user's choice)")
                AutomaticUpdates:             \(config.automaticUpdates.map(String.init) ?? "(user's choice)")
                UpdateDeferralDays:           \(config.updateDeferralDays.map(String.init) ?? "(user's choice)")
                LogFilePath:                  \(config.effectiveLogFilePath())
                """)
            }
            return ExitStatus.success.rawValue

        case "uninstall":
            guard args.positional.isEmpty else { throw DecantError(.usage, "uninstall takes no arguments") }
            guard geteuid() == 0 else { throw DecantError(.notAuthorized, "uninstall may only be used by root") }
            // The log file is one of the things being removed, so this run only logs to stderr
            // and the unified log.
            let config = try loadConfiguration(args, log: log, userHint: nil)
            let uninstaller = Uninstaller(config: config, log: log)
            uninstaller.helperExecutable = Bundle.main.executablePath
            let report = uninstaller.uninstall(dryRun: args.dryRun)
            if args.json {
                emitJSON(report)
            } else if !args.quiet {
                let verb = args.dryRun ? "Would remove" : "Removed"
                report.removed.forEach { print("\(verb) \($0)") }
                report.problems.forEach { print("Not removed: \($0)") }
                print("RESULT \(report.exitCode == 0 ? (args.dryRun ? "wouldUninstall" : "uninstalled") : "incomplete") exit=\(report.exitCode)")
            }
            return report.exitCode

        case "_update-service":
            guard geteuid() == 0 else { throw DecantError(.notAuthorized, "\(command) may only be used by root") }
            try UpdateService.listen {
                let log = Log()
                log.quiet = true
                let config = (try? loadConfiguration(args, log: log, userHint: TargetUser.consoleUser()?.name))
                    ?? ConfigurationLoader().load(userName: nil).0
                log.attachFile(at: config.effectiveLogFilePath())
                let updater = Updater(config: config, log: log, currentVersion: version)
                updater.executablePath = Bundle.main.executablePath
                return updater
            }

        case "update":
            guard args.positional.isEmpty else { throw DecantError(.usage, "update takes no arguments") }
            // Testing options: root can install any package anyway, so they give nobody new powers.
            if args.feed != nil || args.allowUnsigned {
                guard geteuid() == 0 else { throw DecantError(.notAuthorized, "--feed and --allow-unsigned may only be used by root") }
                guard args.feed != nil else { throw DecantError(.usage, "--allow-unsigned needs --feed") }
            }
            let user = geteuid() == 0 ? TargetUser.consoleUser()?.name : TargetUser.lookup(uid: getuid())?.name
            let config = try loadConfiguration(args, log: log, userHint: user)
            if !args.checkOnly { log.attachFile(at: config.effectiveLogFilePath()) }
            let updater = Updater(config: config, log: log, currentVersion: version)
            updater.executablePath = Bundle.main.executablePath
            updater.testFeed = args.feed.map { URL(fileURLWithPath: $0).standardizedFileURL }
            updater.allowUnsigned = args.allowUnsigned
            let report: UpdateReport
            if args.latest, !args.checkOnly, geteuid() != 0 {
                // Only root installs; the service does it for everyone else.
                do {
                    report = try UpdateService.requestUpdate()
                } catch let error as DecantError {
                    var failed = UpdateReport(action: .failed, message: error.message, currentVersion: version)
                    failed.exitCode = error.status.rawValue
                    report = failed
                }
                if report.action == .failed { log.error(report.message) } else { log.info(report.message) }
            } else {
                let mode: UpdateMode = args.latest ? (geteuid() == 0 ? .latest : .requested) : .automatic
                report = updater.run(checkOnly: args.checkOnly, mode: mode)
            }
            if args.json {
                emitJSON(report)
            } else if !args.quiet {
                print("RESULT \(report.action.rawValue) exit=\(report.exitCode): \(report.message.escapingControlCharacters)")
            }
            return report.exitCode

        case "version", "--version":
            print(version)
            return ExitStatus.success.rawValue

        case "help", "--help", "-h":
            print(usage)
            return ExitStatus.success.rawValue

        default:
            throw DecantError(.usage, "Unknown command \(command)\n\n\(usage)")
        }
    } catch let error as DecantError {
        if error.status == .success {
            print(error.message)
        } else {
            log.error(error.message)
        }
        return error.status.rawValue
    } catch {
        log.error(error.localizedDescription)
        return ExitStatus.failure.rawValue
    }
}

exit(run())
