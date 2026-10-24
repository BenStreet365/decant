import CryptoKit
import Darwin
import Foundation
import IOKit

/// Which of decant's packages is installed, so updates install the same one.
public enum PackageEdition: String, Codable, Sendable {
    /// `decant-full-<version>.pkg`: the tool, Decant.app and the update daemon.
    case full
    /// `decant-cli-<version>.pkg`: the tool and the update daemon, without Decant.app.
    case cli

    public func packageName(_ version: String) -> String {
        switch self {
        case .full: "decant-full-\(version).pkg"
        case .cli: "decant-cli-\(version).pkg"
        }
    }

    /// The full package if Decant.app is installed, or the installed package's receipt lists it;
    /// otherwise the command-line package. A Mac that once had the full package keeps getting it.
    public static func detect(appExists: Bool, receiptFiles: [String]?) -> PackageEdition {
        let app = String(Uninstaller.appPath.dropFirst())
        return appExists || receiptFiles?.contains(app) == true ? .full : .cli
    }

    /// The edition installed on this Mac.
    public static func installed() -> PackageEdition {
        let appExists = FileManager.default.fileExists(atPath: Uninstaller.appPath)
        if appExists { return .full }
        let result = try? Command.run("/usr/sbin/pkgutil", ["--files", Uninstaller.packageIdentifier], timeout: 60)
        let files = result.flatMap { $0.status == 0 && !$0.timedOut ? $0.stdoutString.split(separator: "\n").map(String.init) : nil }
        return detect(appExists: false, receiptFiles: files)
    }
}

/// A release of decant on GitHub that can be installed: published, not a draft or pre-release,
/// with an installer package and its checksum. Macs without Decant.app skip a release that has no
/// command-line package.
public struct Release: Codable, Sendable, Equatable {
    public var version: String
    public var publishedAt: Date
    public var packageURL: URL
    public var checksumURL: URL
    public var cliPackageURL: URL?
    public var cliChecksumURL: URL?

    public init(version: String, publishedAt: Date, packageURL: URL, checksumURL: URL,
                cliPackageURL: URL? = nil, cliChecksumURL: URL? = nil) {
        self.version = version
        self.publishedAt = publishedAt
        self.packageURL = packageURL
        self.checksumURL = checksumURL
        self.cliPackageURL = cliPackageURL
        self.cliChecksumURL = cliChecksumURL
    }

    /// The edition's package and checksum, if this release has them.
    public func package(_ edition: PackageEdition) -> (package: URL, checksum: URL)? {
        switch edition {
        case .full: (packageURL, checksumURL)
        case .cli: cliPackageURL.flatMap { package in cliChecksumURL.map { (package, $0) } }
        }
    }
}

public enum UpdateAction: String, Codable, Sendable {
    /// `AutomaticUpdates` is off.
    case disabled
    case upToDate
    /// A newer release exists but was published less than `UpdateDeferralDays` ago.
    case deferred
    /// A release can be installed once the Mac is idle and no install is running.
    case waitingForIdle
    /// `update --check` found a newer release.
    case available
    case updated
    case failed
}

/// What started an update, which decides which settings apply.
public enum UpdateMode: String, Codable, Sendable {
    /// The hourly daemon: `AutomaticUpdates`, `UpdateDeferralDays` and the idle wait all apply.
    case automatic
    /// A user asked for the newest release (Check for Updates in Decant.app, or `decant update
    /// --latest` without root), through `UpdateService`. Installed now, whatever the user's own
    /// choices, unless a profile turns `AutomaticUpdates` off or sets `UpdateDeferralDays`.
    case requested
    /// `sudo decant update --latest`: the newest release now, whatever the settings.
    case latest
}

public struct UpdateReport: Codable, Sendable, Equatable {
    public var action: UpdateAction
    public var exitCode: Int32 = ExitStatus.success.rawValue
    public var message: String
    public var date: Date
    public var currentVersion: String
    public var availableVersion: String?
    /// When `availableVersion` may be installed automatically.
    public var installableAfter: Date?

    public init(action: UpdateAction, message: String, date: Date = Date(), currentVersion: String) {
        self.action = action
        self.message = message
        self.date = date
        self.currentVersion = currentVersion
    }
}

/// What the update daemon remembers between runs. Root writes it; Decant.app reads it to show
/// the update status in its settings.
public struct UpdateState: Codable, Sendable, Equatable {
    public static let directory = "/Library/Application Support/\(Configuration.domain)"
    public static let path = directory + "/Update.json"

    public var lastCheck: Date?
    /// GitHub's ETag for `releases`. A conditional request that returns 304 does not count
    /// against the API's rate limit, which many Macs behind one address share.
    public var etag: String?
    public var releases: [Release] = []
    /// The last outcome of a run that could install (not `--check`).
    public var lastReport: UpdateReport?

    public init() {}

    /// The saved state, or nil if there is none or it cannot be trusted (not a regular file owned
    /// by root and writable only by root).
    public static func load(from path: String = UpdateState.path, requireRootOwnership: Bool = true) -> UpdateState? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        if requireRootOwnership, st.st_uid != 0 || st.st_mode & (S_IWGRP | S_IWOTH) != 0 { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? Updater.decoder.decode(UpdateState.self, from: data)
    }

    public func save(to path: String = UpdateState.path) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        // Atomic: written to a new file and renamed over the old one, never through a symlink.
        try Updater.encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, 0o644)
    }
}

/// Whether updates are installed automatically and how long after a release. A profile's
/// `AutomaticUpdates` and `UpdateDeferralDays` win; otherwise the logged-in user's choices in
/// Decant.app apply, defaulting to on and `Configuration.defaultUpdateDeferralDays`.
public struct UpdatePolicy: Equatable, Sendable {
    /// Keys in Decant.app's defaults domain that hold the user's choices.
    public static let automaticUpdatesKey = "AutomaticUpdates"
    public static let deferralDaysKey = "UpdateDeferralDays"

    public var automatic: ManagedSetting
    public var deferralDays: ManagedValue<Int>

    public init(config: Configuration, userEnabled: Bool?, userDeferralDays: Int?) {
        automatic = ManagedSetting(managed: config.automaticUpdates, userChoice: userEnabled ?? true)
        let days = userDeferralDays.map { min(max($0, 0), Configuration.maxUpdateDeferralDays) }
            ?? Configuration.defaultUpdateDeferralDays
        deferralDays = ManagedValue(managed: config.updateDeferralDays, userChoice: days)
    }
}

/// Keeps decant, and Decant.app if it is installed, up to date from GitHub releases. Run by the
/// `uk.street365.decant.update` LaunchDaemon as `decant update`: it checks GitHub at most once a
/// day and installs the newest release that has been out for the deferral period, once nobody
/// has used the Mac for `requiredIdleTime`. The package must be signed by the same Developer ID
/// team as the running binary and notarised.
public final class Updater {
    public static let repository = "BenStreet365/decant"
    public static let daemonLabel = "\(Configuration.domain).update"
    public static let daemonPlistPath = "/Library/LaunchDaemons/\(daemonLabel).plist"
    public static let checkInterval: TimeInterval = 24 * 3600
    public static let requiredIdleTime: TimeInterval = 10 * 60
    static let maxPackageSize = 200 * 1024 * 1024
    static let installerTimeout: TimeInterval = 900

    public let config: Configuration
    public let log: Log
    public let currentVersion: String
    /// The running decant binary, whose Team ID a package must be signed with.
    public var executablePath: String?
    public var statePath = UpdateState.path
    public var effectiveUID: uid_t = geteuid()
    /// Tests turn this off to use a state file they wrote themselves.
    var stateMustBeRootOwned = true
    /// Testing only (root, `update --feed`): a local `releases.json` in GitHub's format, used
    /// instead of GitHub. Its assets must be files in the same folder. Its releases are not saved
    /// to the state, so later runs go back to GitHub.
    public var testFeed: URL?
    /// Testing only (root, `update --feed --allow-unsigned`): skips the signature and Gatekeeper
    /// checks of the package, so a local ad-hoc build can be installed. The checksum still applies.
    public var allowUnsigned = false
    /// The package updates install. `run` detects it if nil.
    public var edition: PackageEdition?

    public init(config: Configuration, log: Log, currentVersion: String) {
        self.config = config
        self.log = log
        self.currentVersion = currentVersion
    }

    /// GitHub is asked at most this often for requested updates, however often users ask.
    static let requestedCheckInterval: TimeInterval = 60

    /// With `checkOnly`, looks for a newer release (always asking GitHub) and reports what `mode`
    /// would install, installing nothing; any user may do that. Otherwise, as root, installs what
    /// `mode` allows: the daemon's run is `.automatic`.
    public func run(checkOnly: Bool, mode: UpdateMode = .automatic) -> UpdateReport {
        let isRoot = effectiveUID == 0
        var state = (isRoot ? UpdateState.load(from: statePath, requireRootOwnership: stateMustBeRootOwned) : nil) ?? UpdateState()
        var report = UpdateReport(action: .upToDate, message: "", currentVersion: currentVersion)
        do {
            report = try check(checkOnly: checkOnly, mode: mode, isRoot: isRoot, state: &state)
        } catch let error as DecantError {
            report.action = .failed
            report.exitCode = error.status.rawValue
            report.message = error.message
        } catch {
            report.action = .failed
            report.exitCode = ExitStatus.updateFailed.rawValue
            report.message = error.localizedDescription
        }

        // The daemon runs hourly, so an outcome is only logged when it differs from the last run's,
        // for example once when an update starts waiting for idle rather than every hour after.
        let repeated = !checkOnly && mode == .automatic && state.lastReport.map { $0.action == report.action && $0.message == report.message } == true
        if !repeated {
            if report.action == .failed { log.error(report.message) } else { log.info(report.message) }
        }
        if isRoot {
            if !checkOnly { state.lastReport = report }
            // A test feed's releases must not stand in for GitHub's in later runs.
            if testFeed != nil, let saved = UpdateState.load(from: statePath, requireRootOwnership: stateMustBeRootOwned) {
                state.releases = saved.releases
                state.etag = saved.etag
                state.lastCheck = saved.lastCheck
            } else if testFeed != nil {
                state.releases = []
                state.etag = nil
                state.lastCheck = nil
            }
            do {
                try state.save(to: statePath)
            } catch {
                log.warning("Cannot save \(statePath): \(error.localizedDescription)")
            }
        }
        return report
    }

    private func check(checkOnly: Bool, mode: UpdateMode, isRoot: Bool, state: inout UpdateState) throws -> UpdateReport {
        var report = UpdateReport(action: .upToDate, message: "decant \(currentVersion) is up to date",
                                  currentVersion: currentVersion)
        let policy = currentPolicy(isRoot: isRoot)
        // A user's request overrides their own choices, never a profile's.
        let blockedByProfile = policy.automatic.isManaged && !policy.automatic.isEnabled
        if mode == .requested && blockedByProfile || mode == .automatic && !checkOnly && !policy.automatic.isEnabled {
            report.action = .disabled
            report.message = policy.automatic.isManaged ? "Automatic updates are turned off by a profile"
                                                        : "Automatic updates are turned off in Decant's settings"
            return report
        }
        var teamID = ""
        if !checkOnly {
            guard isRoot else {
                throw DecantError(.notAuthorized, "update may only be used by root; use --check to look for a new version")
            }
            if !allowUnsigned { teamID = try ownTeamID() }
        }
        if testFeed != nil {
            guard isRoot else { throw DecantError(.notAuthorized, "--feed may only be used by root") }
            try refreshFromTestFeed(&state)
        } else if checkOnly || mode == .latest
                    || state.lastCheck.map({ Date().timeIntervalSince($0) >= (mode == .requested ? Self.requestedCheckInterval : Self.checkInterval) }) ?? true {
            try refresh(&state, useETag: isRoot)
        }

        let days = switch mode {
        case .automatic: policy.deferralDays.value
        case .requested: policy.deferralDays.isManaged ? policy.deferralDays.value : 0
        case .latest: 0
        }
        let edition = edition ?? PackageEdition.installed()
        let releases = state.releases.filter { $0.package(edition) != nil }
        guard let next = Self.next(releases, newerThan: currentVersion) else { return report }
        let installable = Self.installable(releases, newerThan: currentVersion, deferralDays: days, now: Date())
        let target = installable ?? next
        report.availableVersion = target.version
        report.installableAfter = Self.installableDate(target, deferralDays: days)

        if checkOnly, installable != nil || mode != .requested {
            report.action = .available
            report.message = installable != nil
                ? "decant \(target.version) is available"
                : "decant \(target.version) is available and will be installed automatically after \(Self.format(report.installableAfter!))"
            return report
        }
        guard let release = installable else {
            report.action = .deferred
            report.message = mode == .requested
                ? "decant \(target.version) can be installed after \(Self.format(report.installableAfter!)): a profile holds updates back for \(days) days"
                : "decant \(target.version) will be installed after \(Self.format(report.installableAfter!)) (\(days)-day deferral)"
            return report
        }
        guard mode != .automatic || Self.isIdle() else {
            report.action = .waitingForIdle
            report.message = "decant \(release.version) will be installed when the Mac is idle"
            return report
        }
        // Waits only briefly: an MDM install, or one in Decant.app, runs the binary being replaced.
        let lock: InstallLock
        do {
            lock = try InstallLock(isRoot: true, timeout: 5)
        } catch let error as DecantError where error.status == .busy {
            guard mode == .automatic else {
                throw DecantError(.busy, "Another install is running; try again when it has finished")
            }
            report.action = .waitingForIdle
            report.message = "decant \(release.version) will be installed when no install is running"
            return report
        }
        defer { lock.release() }

        try install(release, edition: edition, teamID: teamID)
        report.action = .updated
        report.message = "Updated decant from \(currentVersion) to \(release.version)"
        return report
    }

    // MARK: Policy

    func currentPolicy(isRoot: Bool) -> UpdatePolicy {
        let (enabled, days) = isRoot ? Self.consoleUserChoices() : Self.ownChoices()
        return UpdatePolicy(config: config, userEnabled: enabled, userDeferralDays: days)
    }

    /// The current user's choices in Decant.app.
    static func ownChoices() -> (Bool?, Int?) {
        let defaults = UserDefaults(suiteName: Uninstaller.appBundleIdentifier)
        return (defaults?.object(forKey: UpdatePolicy.automaticUpdatesKey) as? Bool,
                defaults?.object(forKey: UpdatePolicy.deferralDaysKey) as? Int)
    }

    /// The console user's choices in Decant.app, read by `defaults` running as that user in their
    /// session, so root never parses a file the user controls. nil when nobody is logged in.
    static func consoleUserChoices() -> (Bool?, Int?) {
        guard let user = TargetUser.consoleUser() else { return (nil, nil) }
        func read(_ key: String) -> String? {
            guard let result = try? Command.run("/bin/launchctl", ["asuser", String(user.uid), "/usr/bin/sudo", "-n", "-u", user.name,
                                                                    "/usr/bin/defaults", "read", Uninstaller.appBundleIdentifier, key],
                                                timeout: 30),
                  result.status == 0, !result.timedOut else { return nil }
            return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let enabled = read(UpdatePolicy.automaticUpdatesKey).flatMap { ["1": true, "0": false][$0] }
        let days = read(UpdatePolicy.deferralDaysKey).flatMap { Int($0) }
        return (enabled, days)
    }

    // MARK: Releases

    /// The newest release newer than `current`, whether or not it can be installed yet.
    public static func newest(_ releases: [Release], newerThan current: String) -> Release? {
        releases.filter { AppBundle.compareVersionStrings($0.version, current) == .orderedDescending }
            .max { AppBundle.compareVersionStrings($0.version, $1.version) == .orderedAscending }
    }

    /// The release newer than `current` published first, so whose deferral ends first: the one
    /// installed next if nothing newer is published. The newest of those published together.
    public static func next(_ releases: [Release], newerThan current: String) -> Release? {
        guard let first = releases.filter({ AppBundle.compareVersionStrings($0.version, current) == .orderedDescending })
            .map(\.publishedAt).min() else { return nil }
        return newest(releases.filter { $0.publishedAt == first }, newerThan: current)
    }

    /// The newest release newer than `current` that was published at least `deferralDays` ago.
    public static func installable(_ releases: [Release], newerThan current: String, deferralDays: Int, now: Date) -> Release? {
        newest(releases.filter { installableDate($0, deferralDays: deferralDays) <= now }, newerThan: current)
    }

    public static func installableDate(_ release: Release, deferralDays: Int) -> Date {
        release.publishedAt.addingTimeInterval(TimeInterval(deferralDays) * 24 * 3600)
    }

    func refresh(_ state: inout UpdateState, useETag: Bool) throws {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=30")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("decant/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if useETag, let etag = state.etag, !state.releases.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try HTTPClient.get(request, maxBytes: 4 * 1024 * 1024, accepting: [200, 304])
        if response.statusCode == 200 {
            state.releases = try Self.parseReleases(data)
            state.etag = response.value(forHTTPHeaderField: "ETag")
        }
        state.lastCheck = Date()
        log.debug("Checked GitHub: \(state.releases.count) releases, newest \(state.releases.first?.version ?? "none")")
    }

    func refreshFromTestFeed(_ state: inout UpdateState) throws {
        guard let feed = testFeed else { return }
        let data = try fetch(feed, maxBytes: 4 * 1024 * 1024)
        state.releases = try Self.parseReleases(data, downloadPrefix: feed.deletingLastPathComponent().standardizedFileURL.absoluteString)
        state.lastCheck = Date()
        log.warning("Testing: read \(state.releases.count) releases from \(feed.path) instead of GitHub")
    }

    /// Downloads over HTTPS, or reads a local file when testing with `testFeed`.
    func fetch(_ url: URL, maxBytes: Int) throws -> Data {
        guard url.isFileURL else { return try HTTPClient.get(URLRequest(url: url), maxBytes: maxBytes).0 }
        guard testFeed != nil else { throw DecantError(.updateFailed, "Refusing to read \(url.path) without --feed") }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw DecantError(.updateFailed, "Cannot read \(url.path)")
        }
        guard data.count <= maxBytes else { throw DecantError(.updateFailed, "\(url.path) is larger than \(maxBytes) bytes") }
        return data
    }

    static let gitHubDownloadPrefix = "https://github.com/\(repository)/releases/download/"

    /// Installable releases from GitHub's `releases` API response. Tags are `v<version>`, with
    /// `decant-full-<version>.pkg` and `decant-full-<version>.pkg.sha256` attached, and usually
    /// `decant-cli-<version>.pkg` and its `.sha256`, downloadable from under `downloadPrefix`.
    static func parseReleases(_ data: Data, downloadPrefix: String = gitHubDownloadPrefix) throws -> [Release] {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }
        struct GitHubRelease: Decodable {
            let tagName: String
            let draft: Bool
            let prerelease: Bool
            let publishedAt: Date?
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let releases: [GitHubRelease]
        do {
            releases = try decoder.decode([GitHubRelease].self, from: data)
        } catch {
            throw DecantError(.updateFailed, "Cannot read the list of releases from GitHub: \(error.localizedDescription)")
        }
        return releases.compactMap { release in
            guard !release.draft, !release.prerelease, let published = release.publishedAt,
                  release.tagName.hasPrefix("v") else { return nil }
            let version = String(release.tagName.dropFirst())
            func asset(_ name: String) -> URL? {
                guard let url = release.assets.first(where: { $0.name == name })?.browserDownloadUrl.standardized,
                      url.absoluteString.hasPrefix(downloadPrefix) else { return nil }
                return url
            }
            let full = PackageEdition.full.packageName(version), cli = PackageEdition.cli.packageName(version)
            guard let package = asset(full), let checksum = asset(full + ".sha256") else { return nil }
            var result = Release(version: version, publishedAt: published, packageURL: package, checksumURL: checksum)
            if let cliPackage = asset(cli), let cliChecksum = asset(cli + ".sha256") {
                result.cliPackageURL = cliPackage
                result.cliChecksumURL = cliChecksum
            }
            return result
        }
    }

    // MARK: Installing

    func install(_ release: Release, edition: PackageEdition, teamID: String) throws {
        guard let urls = release.package(edition) else {
            throw DecantError(.updateFailed, "decant \(release.version) has no \(edition.packageName(release.version))")
        }
        let directory = try Self.makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = edition.packageName(release.version)
        let package = directory.appendingPathComponent(name)

        log.info("Downloading decant \(release.version) from \(urls.package.absoluteString)")
        let data = try fetch(urls.package, maxBytes: Self.maxPackageSize)
        let checksumData = try fetch(urls.checksum, maxBytes: 4096)
        guard let expected = Self.parseChecksum(String(decoding: checksumData, as: UTF8.self)) else {
            throw DecantError(.updateFailed, "Cannot read the checksum of \(name)")
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw DecantError(.updateFailed, "\(name) does not match its published checksum")
        }
        try data.write(to: package, options: .withoutOverwriting)

        if allowUnsigned {
            log.warning("Testing: not checking the signature of \(package.lastPathComponent)")
        } else {
            try verifyPackage(package, teamID: teamID)
        }
        try verifyPackageVersion(package, release: release)
        log.info("Installing decant \(release.version)")
        let result = try Command.run("/usr/sbin/installer", ["-pkg", package.path, "-target", "/"], timeout: Self.installerTimeout)
        guard result.status == 0, !result.timedOut else {
            let detail = (result.stderrString + result.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DecantError(.updateFailed, "installer could not install decant \(release.version): \(result.timedOut ? "timed out" : detail)")
        }
    }

    /// The package must be signed with a Developer ID Installer certificate from the same team as
    /// the running binary, and Gatekeeper must accept it as notarised.
    func verifyPackage(_ package: URL, teamID: String) throws {
        let signature = try Command.run("/usr/sbin/pkgutil", ["--check-signature", package.path], timeout: 120)
        guard signature.status == 0, let packageTeam = Self.installerTeamID(fromCheckSignature: signature.stdoutString) else {
            throw DecantError(.invalidSignature, "\(package.lastPathComponent) is not signed with a Developer ID Installer certificate")
        }
        guard packageTeam == teamID else {
            throw DecantError(.teamNotAllowed, "\(package.lastPathComponent) is signed by team \(packageTeam), not \(teamID)")
        }
        let assessment = try Command.run("/usr/sbin/spctl", ["--assess", "--type", "install", "-vv", package.path], timeout: 120)
        let detail = (assessment.stderrString + assessment.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.contains("override=") {
            throw DecantError(.gatekeeperRejected, "Gatekeeper did not assess \(package.lastPathComponent), so its notarisation cannot be checked: \(detail)")
        }
        if let reason = Installer.gatekeeperRejection(status: assessment.status, output: detail) {
            throw DecantError(.gatekeeperRejected, "Gatekeeper rejected \(package.lastPathComponent): \(reason)")
        }
        log.info("Verified \(package.lastPathComponent): signed by team \(packageTeam) and notarised")
    }

    /// The version inside the package must be the release's, and newer than this one. The tag
    /// alone is not enough: an old, genuinely signed package published under a newer tag would
    /// otherwise roll every Mac back to it.
    func verifyPackageVersion(_ package: URL, release: Release) throws {
        guard let version = try Self.packageVersion(of: package) else {
            throw DecantError(.updateFailed, "\(package.lastPathComponent) does not contain a \(Configuration.domain) package with a version")
        }
        guard version == release.version else {
            throw DecantError(.updateFailed, "\(package.lastPathComponent) contains decant \(version.escapingControlCharacters), not \(release.version)")
        }
        guard AppBundle.compareVersionStrings(version, currentVersion) == .orderedDescending else {
            throw DecantError(.updateFailed, "\(package.lastPathComponent) contains decant \(version), which is not newer than \(currentVersion)")
        }
    }

    /// The version of the `uk.street365.decant` component in a flat package, read from its
    /// PackageInfo. Run only on a package whose signature has been checked.
    static func packageVersion(of package: URL) throws -> String? {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expanded = directory.appendingPathComponent("expanded")
        let result = try Command.run("/usr/sbin/pkgutil", ["--expand", package.path, expanded.path], timeout: 300)
        guard result.status == 0, !result.timedOut else {
            throw DecantError(.updateFailed, "Cannot expand \(package.lastPathComponent): \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // pkgbuild makes a component package with PackageInfo at the top; a product archive has
        // one folder per component.
        var candidates = [expanded.appendingPathComponent("PackageInfo")]
        let entries = (try? FileManager.default.contentsOfDirectory(at: expanded, includingPropertiesForKeys: nil)) ?? []
        candidates += entries.sorted { $0.path < $1.path }.map { $0.appendingPathComponent("PackageInfo") }
        for candidate in candidates {
            var st = stat()
            guard lstat(candidate.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                  let data = FileManager.default.contents(atPath: candidate.path) else { continue }
            if let version = packageVersion(fromPackageInfo: data) { return version }
        }
        return nil
    }

    static func packageVersion(fromPackageInfo data: Data) -> String? {
        guard let document = try? XMLDocument(data: data), let root = document.rootElement(), root.name == "pkg-info",
              root.attribute(forName: "identifier")?.stringValue == Configuration.domain,
              let version = root.attribute(forName: "version")?.stringValue, !version.isEmpty else { return nil }
        return version
    }

    /// The Team ID of the running binary. A copy that is not Developer ID signed (a local build)
    /// has nothing to check packages against, so it never updates itself.
    func ownTeamID() throws -> String {
        guard let path = executablePath else { throw DecantError(.updateFailed, "Cannot find the decant executable") }
        let info = try CodeSignature.inspect(URL(fileURLWithPath: path))
        guard !info.isAdHoc, info.states.contains(.developerID), let team = info.teamID else {
            throw DecantError(.invalidSignature, "This copy of decant is not signed with a Developer ID, so updates cannot be verified")
        }
        return team
    }

    /// The Team ID in the leaf certificate of `pkgutil --check-signature` output, if the package
    /// is signed with a Developer ID Installer certificate that chains to Apple.
    static func installerTeamID(fromCheckSignature output: String) -> String? {
        guard output.contains("Status: signed by a developer certificate issued by Apple for distribution") else { return nil }
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("1. ") else { continue }
            guard text.hasPrefix("1. Developer ID Installer: "), text.hasSuffix(")"),
                  let open = text.lastIndex(of: "(") else { return nil }
            let team = text[text.index(after: open)..<text.index(before: text.endIndex)]
            return team.isEmpty ? nil : String(team)
        }
        return nil
    }

    /// The hash from a `shasum -a 256` line ("<hex>  <file>").
    static func parseChecksum(_ text: String) -> String? {
        guard let hash = text.split(whereSeparator: \.isWhitespace).first?.lowercased(),
              hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
        return hash
    }

    static func makePrivateDirectory() throws -> URL {
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("decant-update.XXXXXX").path.utf8CString)
        guard let path = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            throw DecantError(.updateFailed, "Cannot create a download folder: \(String(cString: strerror(errno)))")
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    // MARK: Idle

    /// Nobody is logged in, or nobody has touched the keyboard or mouse for `requiredIdleTime`.
    public static func isIdle() -> Bool {
        guard TargetUser.consoleUser() != nil else { return true }
        guard let idle = systemIdleTime() else { return false }
        return idle >= requiredIdleTime
    }

    /// Seconds since the last keyboard, mouse or trackpad input.
    public static func systemIdleTime() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return value.doubleValue / 1_000_000_000
    }

    // MARK: Helpers

    static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Blocking HTTPS GETs that refuse to follow a redirect to anything but HTTPS.
final class HTTPClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = HTTPClient()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    static func get(_ request: URLRequest, maxBytes: Int, accepting statuses: Set<Int> = [200]) throws -> (Data, HTTPURLResponse) {
        try shared.get(request, maxBytes: maxBytes, accepting: statuses)
    }

    func get(_ request: URLRequest, maxBytes: Int, accepting statuses: Set<Int>) throws -> (Data, HTTPURLResponse) {
        let url = request.url?.absoluteString ?? "?"
        guard request.url?.scheme == "https" else { throw DecantError(.updateFailed, "Refusing to download \(url) without HTTPS") }
        final class Box: @unchecked Sendable {
            var data: Data?
            var response: URLResponse?
            var error: Error?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            done.signal()
        }
        task.resume()
        done.wait()
        if let error = box.error {
            throw DecantError(.updateFailed, "Cannot download \(url): \(error.localizedDescription)")
        }
        guard let response = box.response as? HTTPURLResponse, statuses.contains(response.statusCode) else {
            let status = (box.response as? HTTPURLResponse)?.statusCode ?? 0
            throw DecantError(.updateFailed, "Cannot download \(url): HTTP \(status)")
        }
        let data = box.data ?? Data()
        guard data.count <= maxBytes else { throw DecantError(.updateFailed, "\(url) is larger than \(maxBytes) bytes") }
        return (data, response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
