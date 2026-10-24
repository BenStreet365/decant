import Foundation
import Testing
@testable import DecantCore

private func signing(team: String?, adHoc: Bool = false, cdHash: String = "aa") -> SigningInfo {
    SigningInfo(teamID: team, signingID: "com.example.app", cdHash: cdHash, isAdHoc: adHoc, states: adHoc ? [] : [.developerID])
}

private let source = signing(team: "TEAM111111")

@Suite struct ExistingTrustTests {
    @Test func sameTeamSameAppIsGenuine() {
        let existing = BundleInspection(bundleIdentifier: "com.example.app", shortVersion: "9", signing: source)
        #expect(ExistingTrust.assess(existing, sourceBundleID: "com.example.app", sourceSigning: source) == .genuine)
    }

    @Test func editedOrResignedCopiesAreUntrusted() {
        // Info.plist edited: the signature no longer holds.
        let tampered = BundleInspection(bundleIdentifier: "com.example.app", shortVersion: "999", problem: "modified")
        // Re-signed ad-hoc, even with another bundle ID.
        let adHoc = BundleInspection(bundleIdentifier: "com.example.other", shortVersion: "999", signing: signing(team: nil, adHoc: true))
        // Same bundle ID, someone else's signature.
        let otherTeam = BundleInspection(bundleIdentifier: "com.example.app", shortVersion: "999", signing: signing(team: "TEAM222222"))
        for existing in [tampered, adHoc, otherTeam] {
            guard case .untrusted = ExistingTrust.assess(existing, sourceBundleID: "com.example.app", sourceSigning: source) else {
                Issue.record("expected untrusted for \(existing)")
                continue
            }
        }
    }

    @Test func realDifferentAppsAreConflicts() {
        let otherVendor = BundleInspection(bundleIdentifier: "com.other.app", signing: signing(team: "TEAM222222"))
        let sameVendor = BundleInspection(bundleIdentifier: "com.example.other", signing: source)
        let notABundle = BundleInspection(problem: "no Info.plist")
        for existing in [otherVendor, sameVendor, notABundle] {
            guard case .conflict = ExistingTrust.assess(existing, sourceBundleID: "com.example.app", sourceSigning: source) else {
                Issue.record("expected conflict for \(existing)")
                continue
            }
        }
    }
}

/// Runs real installs, without root, into a temporary home folder.
@Suite(.serialized) struct InstallFlowTests {
    let home: URL
    let volume: FakeVolume
    let user: TargetUser

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        volume = try FakeVolume()
        let me = TargetUser.lookup(uid: getuid())!
        user = TargetUser(name: me.name, uid: me.uid, gid: me.gid, home: home)
    }

    func installer(adHoc: Bool = true) -> Installer {
        var config = Configuration()
        config.requireGatekeeperAssessment = false
        config.allowAdHocSignatures = adHoc
        let log = Log()
        log.quiet = true
        let installer = Installer(config: config, log: log)
        installer.registersWithLaunchServices = false
        return installer
    }

    func signedApp(version: String) throws -> AppBundle {
        let app = try volume.app("Test.app", version: version)
        let result = try Command.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        #expect(result.status == 0)
        return try AppBundle(url: app)
    }

    func install(_ app: AppBundle, _ installer: Installer, request: InstallRequest = InstallRequest(diskImagePath: "x.dmg")) -> InstallReport {
        var report = InstallReport(action: .failed, exitCode: 1, message: "", diskImage: "x.dmg")
        do {
            try installer.installApp(app, for: user, request: request, report: &report)
        } catch {
            installer.record(error, in: &report)
        }
        return report
    }

    var applications: URL { home.appendingPathComponent("Applications") }

    func installedVersion() throws -> String? {
        try AppBundle(url: applications.appendingPathComponent("Test.app")).shortVersion
    }

    @Test func installsUpdatesAndCleansUp() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(install(try signedApp(version: "1.0"), installer()).action == .installed)
        #expect(try installedVersion() == "1.0")

        let update = install(try signedApp(version: "2.0"), installer())
        #expect(update.action == .updated)
        #expect(update.previousVersion == "1.0")
        #expect(try installedVersion() == "2.0")
        // The previous copy is deleted, not left behind under its hidden name.
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["Test.app"])
    }

    @Test func editedVersionCannotBlockUpdates() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(install(try signedApp(version: "1.0"), installer()).action == .installed)

        // The user bumps the version of their copy to pin it.
        let plist = applications.appendingPathComponent("Test.app/Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        info["CFBundleShortVersionString"] = "999"
        info["CFBundleVersion"] = "999"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)

        let report = install(try signedApp(version: "1.1"), installer())
        #expect(report.action == .updated)
        #expect(try installedVersion() == "1.1")
    }

    @Test func adHocIsRefusedByDefault() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(install(try signedApp(version: "1.0"), installer(adHoc: false)).exitCode == ExitStatus.invalidSignature.rawValue)
    }

    @Test func expectedIdentityIsEnforced() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try signedApp(version: "1.0")
        let wrongBundle = install(app, installer(), request: InstallRequest(diskImagePath: "x.dmg", expectedBundleID: "com.example.other"))
        #expect(wrongBundle.exitCode == ExitStatus.bundleIDMismatch.rawValue)
        let wrongTeam = install(app, installer(), request: InstallRequest(diskImagePath: "x.dmg", expectedTeamID: "TEAM111111"))
        #expect(wrongTeam.exitCode == ExitStatus.teamNotAllowed.rawValue)
        #expect(!FileManager.default.fileExists(atPath: applications.appendingPathComponent("Test.app").path))
    }

    @Test func installIsBoundToTheCheckedCopy() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let checked = install(try signedApp(version: "1.0"), installer(), request: InstallRequest(diskImagePath: "x.dmg", dryRun: true))
        #expect(checked.action == .wouldInstall)
        let cdHash = try #require(checked.cdHash)

        // The disk image changed between the check and Install.
        var request = InstallRequest(diskImagePath: "x.dmg", expectedBundleID: "com.example.app")
        request.expectedCDHash = cdHash
        let swapped = install(try signedApp(version: "2.0"), installer(), request: request)
        #expect(swapped.exitCode == ExitStatus.bundleIDMismatch.rawValue)
        #expect(!FileManager.default.fileExists(atPath: applications.appendingPathComponent("Test.app").path))

        #expect(install(try signedApp(version: "1.0"), installer(), request: request).action == .installed)
    }
}

@Suite struct TimeoutTests {
    @Test func commandTimeoutKillsChild() throws {
        let result = try Command.run("/bin/sleep", ["30"], timeout: 0.5)
        #expect(result.timedOut)
        #expect(result.status != 0)
    }

    /// More concurrent callers than CPUs, as when tests run in parallel on a small CI runner.
    @Test func concurrentCommandsDoNotStarve() async {
        let count = ProcessInfo.processInfo.activeProcessorCount * 4
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<count {
                group.addTask { (try? Command.run("/bin/echo", ["hi"], timeout: 30))?.status == 0 }
            }
            for await succeeded in group { #expect(succeeded) }
        }
    }

    @Test func lockGivesUpWhenHeld() throws {
        let held = try InstallLock(isRoot: false)
        defer { held.release() }
        #expect(throws: DecantError.self) { _ = try InstallLock(isRoot: false, timeout: 0.5) }
    }
}
