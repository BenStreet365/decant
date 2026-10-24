import Foundation
import Testing
@testable import DecantCore

@Suite struct UpdaterTests {
    static let downloads = "https://github.com/BenStreet365/decant/releases/download"

    func release(_ version: String, daysAgo: Double, now: Date) -> Release {
        Release(version: version, publishedAt: now.addingTimeInterval(-daysAgo * 24 * 3600),
                packageURL: URL(string: "\(Self.downloads)/v\(version)/decant-full-\(version).pkg")!,
                checksumURL: URL(string: "\(Self.downloads)/v\(version)/decant-full-\(version).pkg.sha256")!)
    }

    @Test func updatesAreOnWithSevenDayDeferralByDefault() {
        let policy = UpdatePolicy(config: Configuration(), userEnabled: nil, userDeferralDays: nil)
        #expect(policy.automatic.isEnabled && !policy.automatic.isManaged)
        #expect(policy.deferralDays == ManagedValue(managed: nil, userChoice: 7))
    }

    @Test func profileOverridesUserUpdateChoices() {
        var config = Configuration()
        config.apply(["AutomaticUpdates": false, "UpdateDeferralDays": 3], source: "test")
        let policy = UpdatePolicy(config: config, userEnabled: true, userDeferralDays: 10)
        #expect(!policy.automatic.isEnabled && policy.automatic.isManaged)
        #expect(policy.deferralDays.value == 3 && policy.deferralDays.isManaged)

        let user = UpdatePolicy(config: Configuration(), userEnabled: false, userDeferralDays: 40)
        #expect(!user.automatic.isEnabled && !user.automatic.isManaged)
        #expect(user.deferralDays.value == 14)
    }

    @Test func deferralDaysAreValidated() {
        var config = Configuration()
        #expect(config.apply(["UpdateDeferralDays": true], source: "test").count == 1)
        #expect(config.updateDeferralDays == nil)
        #expect(config.apply(["UpdateDeferralDays": "7"], source: "test").count == 1)
        #expect(config.updateDeferralDays == nil)
        #expect(config.apply(["UpdateDeferralDays": 30], source: "test").count == 1)
        #expect(config.updateDeferralDays == 14)
        #expect(config.apply(["UpdateDeferralDays": -1], source: "test").count == 1)
        #expect(config.updateDeferralDays == 0)
        #expect(config.apply(["UpdateDeferralDays": 0, "AutomaticUpdates": true], source: "test").isEmpty)
        #expect(config.updateDeferralDays == 0 && config.automaticUpdates == true)
    }

    @Test func installsNewestReleaseOutsideTheDeferral() {
        let now = Date()
        let releases = [release("0.3.0", daysAgo: 2, now: now), release("0.2.0", daysAgo: 9, now: now),
                        release("0.1.5", daysAgo: 20, now: now), release("0.1.0", daysAgo: 30, now: now)]
        #expect(Updater.newest(releases, newerThan: "0.1.0")?.version == "0.3.0")
        #expect(Updater.installable(releases, newerThan: "0.1.0", deferralDays: 7, now: now)?.version == "0.2.0")
        #expect(Updater.installable(releases, newerThan: "0.1.0", deferralDays: 0, now: now)?.version == "0.3.0")
        #expect(Updater.installable(releases, newerThan: "0.1.0", deferralDays: 14, now: now)?.version == "0.1.5")
        #expect(Updater.installable(releases, newerThan: "0.2.0", deferralDays: 7, now: now) == nil)
        #expect(Updater.newest(releases, newerThan: "0.3.0") == nil)
        // While nothing is installable, the release reported is the one whose deferral ends first.
        #expect(Updater.next(releases, newerThan: "0.1.5")?.version == "0.2.0")
        #expect(Updater.next(releases, newerThan: "0.3.0") == nil)
        // Never a downgrade, even when the installed copy is newer than every release.
        #expect(Updater.installable(releases, newerThan: "1.0", deferralDays: 0, now: now) == nil)
        #expect(Updater.newest([release("0.10.0", daysAgo: 1, now: now), release("0.9.0", daysAgo: 1, now: now)],
                               newerThan: "0.1.0")?.version == "0.10.0")
    }

    @Test func parsesOnlyPublishedReleasesWithPackages() throws {
        func asset(_ tag: String, _ name: String, host: String = "github.com") -> [String: Any] {
            ["name": name, "browser_download_url": "https://\(host)/BenStreet365/decant/releases/download/\(tag)/\(name)"]
        }
        func entry(_ tag: String, draft: Bool = false, prerelease: Bool = false, assets: [[String: Any]]? = nil) -> [String: Any] {
            let version = tag.dropFirst()
            return ["tag_name": tag, "draft": draft, "prerelease": prerelease, "published_at": "2026-10-01T12:00:00Z",
                    "assets": assets ?? [asset(tag, "decant-full-\(version).pkg"), asset(tag, "decant-full-\(version).pkg.sha256")]]
        }
        let json: [[String: Any]] = [
            entry("v0.4.0"),
            entry("v0.5.0-beta.1", prerelease: true),
            entry("v0.6.0", draft: true),
            entry("v0.3.0", assets: [asset("v0.3.0", "decant-full-0.3.0.pkg")]),
            entry("v0.2.0", assets: [asset("v0.2.0", "decant-full-0.2.0.pkg", host: "example.com"),
                                     asset("v0.2.0", "decant-full-0.2.0.pkg.sha256")]),
            entry("latest"),
        ]
        let releases = try Updater.parseReleases(JSONSerialization.data(withJSONObject: json))
        #expect(releases.map(\.version) == ["0.4.0"])
        #expect(releases.first?.packageURL.absoluteString == "\(Self.downloads)/v0.4.0/decant-full-0.4.0.pkg")
        #expect(releases.first?.publishedAt == Date(timeIntervalSince1970: 1_790_856_000))
        #expect(throws: DecantError.self) { try Updater.parseReleases(Data("{\"message\":\"rate limited\"}".utf8)) }
    }

    @Test func parsesCommandLinePackages() throws {
        func asset(_ name: String) -> [String: Any] {
            ["name": name, "browser_download_url": "\(Self.downloads)/v0.4.0/\(name)"]
        }
        func entry(_ names: [String]) -> [String: Any] {
            ["tag_name": "v0.4.0", "draft": false, "prerelease": false, "published_at": "2026-10-01T12:00:00Z",
             "assets": names.map(asset)]
        }
        let both = try Updater.parseReleases(JSONSerialization.data(withJSONObject: [entry(
            ["decant-full-0.4.0.pkg", "decant-full-0.4.0.pkg.sha256", "decant-cli-0.4.0.pkg", "decant-cli-0.4.0.pkg.sha256"])]))
        #expect(both.first?.package(.cli)?.package.absoluteString == "\(Self.downloads)/v0.4.0/decant-cli-0.4.0.pkg")
        #expect(both.first?.package(.cli)?.checksum.absoluteString == "\(Self.downloads)/v0.4.0/decant-cli-0.4.0.pkg.sha256")
        #expect(both.first?.package(.full)?.package.absoluteString == "\(Self.downloads)/v0.4.0/decant-full-0.4.0.pkg")

        // A command-line package without its checksum is not used; the full package still is.
        let fullOnly = try Updater.parseReleases(JSONSerialization.data(withJSONObject: [entry(
            ["decant-full-0.4.0.pkg", "decant-full-0.4.0.pkg.sha256", "decant-cli-0.4.0.pkg"])]))
        #expect(fullOnly.count == 1 && fullOnly.first?.package(.cli) == nil)
        // The full package is required.
        #expect(try Updater.parseReleases(JSONSerialization.data(withJSONObject: [entry(
            ["decant-cli-0.4.0.pkg", "decant-cli-0.4.0.pkg.sha256"])])).isEmpty)
    }

    @Test func detectsInstalledEdition() {
        #expect(PackageEdition.detect(appExists: true, receiptFiles: nil) == .full)
        #expect(PackageEdition.detect(appExists: false, receiptFiles: ["Applications", "Applications/Decant.app", "usr/local/bin/decant"]) == .full)
        #expect(PackageEdition.detect(appExists: false, receiptFiles: ["usr", "usr/local/bin/decant"]) == .cli)
        #expect(PackageEdition.detect(appExists: false, receiptFiles: nil) == .cli)
        #expect(PackageEdition.full.packageName("1.2.0") == "decant-full-1.2.0.pkg")
        #expect(PackageEdition.cli.packageName("1.2.0") == "decant-cli-1.2.0.pkg")
    }

    @Test func testFeedAssetsMustBeInItsFolder() throws {
        func entry(_ base: String) -> [String: Any] {
            ["tag_name": "v0.2.0", "draft": false, "prerelease": false, "published_at": "2026-10-01T12:00:00Z",
             "assets": [["name": "decant-full-0.2.0.pkg", "browser_download_url": "\(base)/decant-full-0.2.0.pkg"],
                        ["name": "decant-full-0.2.0.pkg.sha256", "browser_download_url": "\(base)/decant-full-0.2.0.pkg.sha256"]]]
        }
        let data = try JSONSerialization.data(withJSONObject: [entry("file:///feed"), entry("file:///feed/../etc")])
        let releases = try Updater.parseReleases(data, downloadPrefix: "file:///feed/")
        #expect(releases.map(\.packageURL.path) == ["/feed/decant-full-0.2.0.pkg"])
        // GitHub's own list never points at local files.
        #expect(try Updater.parseReleases(data).isEmpty)
    }

    @Test func readsTeamIDFromPackageSignature() {
        let signed = """
        Package "decant-full-0.2.0.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Signed with a trusted timestamp on: 2026-10-01 12:00:00 +0000
           Certificate Chain:
            1. Developer ID Installer: Ben Street (ABCDE12345)
               Expires: 2031-01-01 00:00:00 +0000
            2. Developer ID Certification Authority
            3. Apple Root CA
        """
        #expect(Updater.installerTeamID(fromCheckSignature: signed) == "ABCDE12345")

        let application = signed.replacingOccurrences(of: "Developer ID Installer", with: "Developer ID Application")
        #expect(Updater.installerTeamID(fromCheckSignature: application) == nil)
        let selfSigned = signed.replacingOccurrences(of: "signed by a developer certificate issued by Apple for distribution",
                                                     with: "signed by a certificate trusted by Mac OS X")
        #expect(Updater.installerTeamID(fromCheckSignature: selfSigned) == nil)
        #expect(Updater.installerTeamID(fromCheckSignature: "Package \"x.pkg\":\n   Status: no signature") == nil)
    }

    @Test func parsesChecksumFile() {
        let hash = String(repeating: "ab", count: 32)
        #expect(Updater.parseChecksum("\(hash)  decant-full-0.2.0.pkg\n") == hash)
        #expect(Updater.parseChecksum(hash.uppercased()) == hash)
        #expect(Updater.parseChecksum("not a hash") == nil)
        #expect(Updater.parseChecksum("") == nil)
    }

    @Test func stateRoundTripsAndMustBeARegularFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Update.json").path
        var state = UpdateState()
        state.lastCheck = Date(timeIntervalSince1970: 1_800_000_000)
        state.etag = "W/\"abc\""
        state.releases = [release("0.2.0", daysAgo: 1, now: Date(timeIntervalSince1970: 1_800_000_000))]
        state.lastReport = UpdateReport(action: .deferred, message: "later", date: Date(timeIntervalSince1970: 1_800_000_000),
                                        currentVersion: "0.1.0")
        try state.save(to: path)
        #expect(UpdateState.load(from: path, requireRootOwnership: false) == state)
        // Written by this (non-root) user, so not trusted when root ownership is required.
        #expect(UpdateState.load(from: path) == nil)

        let link = dir.appendingPathComponent("link.json").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        #expect(UpdateState.load(from: link, requireRootOwnership: false) == nil)
    }

    @Test func installingNeedsRoot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = Configuration()
        config.automaticUpdates = true
        let log = Log()
        log.quiet = true
        let updater = Updater(config: config, log: log, currentVersion: "0.1.0")
        updater.effectiveUID = 501
        updater.statePath = dir.appendingPathComponent("Update.json").path
        let report = updater.run(checkOnly: false)
        #expect(report.action == .failed)
        #expect(report.exitCode == ExitStatus.notAuthorized.rawValue)

        config.automaticUpdates = false
        let disabled = Updater(config: config, log: log, currentVersion: "0.1.0").run(checkOnly: false)
        #expect(disabled.action == .disabled && disabled.exitCode == 0)
    }

    @Test func repeatedOutcomesAreLoggedOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logPath = dir.appendingPathComponent("decant.log").path
        var config = Configuration()
        config.automaticUpdates = false
        func runOnce() -> UpdateReport {
            let log = Log()
            log.quiet = true
            log.attachFile(at: logPath)
            let updater = Updater(config: config, log: log, currentVersion: "0.1.0")
            updater.effectiveUID = 0
            updater.statePath = dir.appendingPathComponent("Update.json").path
            updater.stateMustBeRootOwned = false
            return updater.run(checkOnly: false)
        }
        func lines() throws -> Int {
            try String(contentsOfFile: logPath, encoding: .utf8).split(separator: "\n").count
        }
        #expect(runOnce().action == .disabled)
        #expect(try lines() == 1)
        #expect(runOnce().action == .disabled)
        #expect(runOnce().action == .disabled)
        #expect(try lines() == 1)

        config.automaticUpdates = true
        // A different outcome (here, refusing an unsigned test binary) is logged again.
        #expect(runOnce().action == .failed)
        #expect(try lines() == 2)
        #expect(runOnce().action == .failed)
        #expect(try lines() == 2)
    }

    /// What `checkOnly` reports in each mode, from a test feed with 0.3.0 out for 2 days and
    /// 0.2.0 for 9, so nothing is downloaded or installed.
    func checkModes(current: String, profile: [String: Any]) throws -> [UpdateMode: UpdateReport] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func entry(_ version: String, daysAgo: Double) -> [String: Any] {
            let published = Date().addingTimeInterval(-daysAgo * 24 * 3600).formatted(.iso8601)
            let base = dir.standardizedFileURL.absoluteString
            return ["tag_name": "v\(version)", "draft": false, "prerelease": false, "published_at": published,
                    "assets": [["name": "decant-full-\(version).pkg", "browser_download_url": "\(base)decant-full-\(version).pkg"],
                               ["name": "decant-full-\(version).pkg.sha256", "browser_download_url": "\(base)decant-full-\(version).pkg.sha256"]]]
        }
        let feed = dir.appendingPathComponent("releases.json")
        try JSONSerialization.data(withJSONObject: [entry("0.3.0", daysAgo: 2), entry("0.2.0", daysAgo: 9)]).write(to: feed)
        var config = Configuration()
        config.apply(profile, source: "test")
        var reports: [UpdateMode: UpdateReport] = [:]
        for mode in [UpdateMode.automatic, .requested, .latest] {
            let log = Log()
            log.quiet = true
            let updater = Updater(config: config, log: log, currentVersion: current)
            updater.effectiveUID = 0
            updater.statePath = dir.appendingPathComponent("Update.json").path
            updater.stateMustBeRootOwned = false
            updater.testFeed = feed
            updater.edition = .full
            reports[mode] = updater.run(checkOnly: true, mode: mode)
        }
        return reports
    }

    @Test func requestedAndLatestUpdatesSkipTheUsersDeferral() throws {
        let reports = try checkModes(current: "0.1.0", profile: [:])
        #expect(reports[.automatic]?.action == .available && reports[.automatic]?.availableVersion == "0.2.0")
        #expect(reports[.requested]?.action == .available && reports[.requested]?.availableVersion == "0.3.0")
        #expect(reports[.latest]?.action == .available && reports[.latest]?.availableVersion == "0.3.0")
    }

    @Test func requestedUpdatesFollowTheProfile() throws {
        // A profile's deferral still holds a requested update back, but not root's --latest.
        let deferred = try checkModes(current: "0.2.0", profile: ["UpdateDeferralDays": 7])
        #expect(deferred[.requested]?.action == .deferred && deferred[.requested]?.availableVersion == "0.3.0")
        #expect(deferred[.latest]?.action == .available && deferred[.latest]?.availableVersion == "0.3.0")
        let older = try checkModes(current: "0.1.0", profile: ["UpdateDeferralDays": 7])
        #expect(older[.requested]?.action == .available && older[.requested]?.availableVersion == "0.2.0")

        let off = try checkModes(current: "0.1.0", profile: ["AutomaticUpdates": false])
        #expect(off[.requested]?.action == .disabled)
        #expect(off[.latest]?.action == .available && off[.latest]?.availableVersion == "0.3.0")
        #expect(off[.automatic]?.action == .available)
    }

    @Test func requestedUpdatesNeedRoot() {
        let log = Log()
        log.quiet = true
        let updater = Updater(config: Configuration(), log: log, currentVersion: "0.1.0")
        updater.effectiveUID = 501
        for mode in [UpdateMode.requested, .latest] {
            let report = updater.run(checkOnly: false, mode: mode)
            #expect(report.action == .failed && report.exitCode == ExitStatus.notAuthorized.rawValue)
        }
    }
}
