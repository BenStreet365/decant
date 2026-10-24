import Foundation
import Testing
@testable import DecantCore

private func installer(allowUserOption: Bool = false, uid: uid_t = getuid()) -> Installer {
    var config = Configuration()
    config.allowUserOption = allowUserOption
    let log = Log()
    log.quiet = true
    let installer = Installer(config: config, log: log)
    installer.effectiveUID = uid
    return installer
}

private func status(_ body: () throws -> Void) -> DecantCore.ExitStatus? {
    do {
        try body()
        return nil
    } catch let error as DecantError {
        return error.status
    } catch {
        return .failure
    }
}

private func report(_ action: InstallReport.Action, _ status: DecantCore.ExitStatus) -> InstallReport {
    InstallReport(action: action, exitCode: status.rawValue, message: "", diskImage: "x.dmg")
}

@Suite struct InstallerTests {
    @Test func userOptionIsRefusedWhenDisabled() {
        let me = TargetUser.lookup(uid: getuid())!.name
        #expect(status { _ = try installer(uid: 0).resolveUser("someone") } == .notAuthorized)
        #expect(status { _ = try installer().resolveUser(me) } == .notAuthorized)
    }

    @Test func userOptionWhenEnabled() {
        let me = TargetUser.lookup(uid: getuid())!.name
        #expect(status { _ = try installer(allowUserOption: true).resolveUser(me) } == nil)
        #expect(status { _ = try installer(allowUserOption: true).resolveUser("root") } == .notAuthorized)
        #expect(status { _ = try installer(allowUserOption: true, uid: 0).resolveUser("no-such-user-\(UUID())") } == .noTargetUser)
        #expect(status { _ = try installer(allowUserOption: true, uid: 0).resolveUser("root") } == .noTargetUser)
    }

    @Test func userInstallsCanBeDisabled() {
        func install(uid: uid_t) -> InstallReport {
            let installer = installer(uid: uid)
            var config = installer.config
            config.allowUserInstalls = false
            let disabled = Installer(config: config, log: installer.log)
            disabled.effectiveUID = uid
            return disabled.install(InstallRequest(diskImagePath: "/nonexistent.dmg", dryRun: true))
        }
        let user = install(uid: getuid() == 0 ? 501 : getuid())
        #expect(user.exitCode == DecantCore.ExitStatus.notAuthorized.rawValue)
        #expect(user.message == Configuration.userInstallsDisabledMessage)
        // Root (the MDM) is unaffected, so this gets as far as looking for the disk image or console user.
        #expect(install(uid: 0).exitCode != DecantCore.ExitStatus.notAuthorized.rawValue)
    }

    @Test func allUsersNeedsRoot() {
        let reports = installer().installForAllUsers(InstallRequest(diskImagePath: "/nonexistent.dmg")) { _ in Configuration() }
        #expect(reports.count == 1)
        #expect(reports[0].exitCode == DecantCore.ExitStatus.notAuthorized.rawValue)
    }

    @Test func gatekeeperRequiresAppleVerifiedSource() {
        let path = "/tmp/App.app"
        #expect(Installer.gatekeeperRejection(status: 0, output: "\(path): accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Example (ABCDE12345)") == nil)
        #expect(Installer.gatekeeperRejection(status: 0, output: "\(path): accepted\nsource=Apple System\norigin=Software Signing") == nil)
        #expect(Installer.gatekeeperRejection(status: 0, output: "\(path): accepted\nsource=Mac App Store") == nil)

        // Gatekeeper disabled on the Mac: spctl accepts without assessing.
        #expect(Installer.gatekeeperRejection(status: 0, output: "\(path): accepted\noverride=security disabled") != nil)
        // A local spctl rule, or no source at all.
        #expect(Installer.gatekeeperRejection(status: 0, output: "\(path): accepted\nsource=My Rule") != nil)
        #expect(Installer.gatekeeperRejection(status: 0, output: "\(path): accepted") != nil)
        #expect(Installer.gatekeeperRejection(status: 3, output: "\(path): rejected\nsource=Unnotarized Developer ID") != nil)
    }

    @Test func combinedExitCodePrefersFailuresOverSkips() {
        #expect(InstallReport.combinedExitCode([report(.installed, .success), report(.unchanged, .success)]) == 0)
        #expect(InstallReport.combinedExitCode([report(.skipped, .appRunning), report(.installed, .success)]) == 40)
        #expect(InstallReport.combinedExitCode([report(.skipped, .appRunning), report(.failed, .gatekeeperRejected)]) == 23)
        #expect(InstallReport.combinedExitCode([]) == 0)
    }

    @Test func accountListKeepsOnlyPeople() {
        let output = """
        _mbsetupuser             248
        alex                     501
        daemon                   1
        jamie                    502
        nobody                   -2
        root                     0
        ad.user                  1234567
        Guest                    201
        """
        #expect(TargetUser.parseAccountList(output) == ["ad.user", "alex", "jamie"])
    }
}
