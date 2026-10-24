import Foundation
import Testing
@testable import DecantCore

@Suite struct InteractiveTests {
    @Test func menuBarIsOffUnlessChosen() {
        #expect(Configuration().showInMenuBar == nil)
        let off = ManagedSetting(managed: nil, userChoice: false)
        #expect(!off.isEnabled && !off.isManaged)
        let chosen = ManagedSetting(managed: nil, userChoice: true)
        #expect(chosen.isEnabled && !chosen.isManaged)
    }

    @Test func profileOverridesUserMenuBarChoice() {
        let forcedOff = ManagedSetting(managed: false, userChoice: true)
        #expect(!forcedOff.isEnabled && forcedOff.isManaged)
        let forcedOn = ManagedSetting(managed: true, userChoice: false)
        #expect(forcedOn.isEnabled && forcedOn.isManaged)
    }

    @Test func disablingUserInstallsTurnsOffMenuBarAndLogin() {
        var config = Configuration()
        #expect(config.allowUserInstalls)
        #expect(config.managedShowInMenuBar == nil && config.managedOpenAtLogin == nil)
        #expect(config.apply(["AllowUserInstalls": "no"], source: "test").count == 1)
        #expect(config.allowUserInstalls)

        config.apply(["AllowUserInstalls": false, "ShowInMenuBar": true, "OpenAtLogin": true], source: "test", scope: .user)
        #expect(!config.allowUserInstalls)
        #expect(config.managedShowInMenuBar == false)
        #expect(config.managedOpenAtLogin == false)
        let menuBar = ManagedSetting(managed: config.managedShowInMenuBar, userChoice: true)
        #expect(!menuBar.isEnabled && menuBar.isManaged)
    }

    @Test func showInMenuBarIsReadFromProfiles() throws {
        var config = Configuration()
        #expect(config.apply(["ShowInMenuBar": "yes"], source: "test").count == 1)
        #expect(config.showInMenuBar == nil)
        config.apply(["ShowInMenuBar": true, "OpenAtLogin": false], source: "test", scope: .user)
        #expect(config.showInMenuBar == true)
        #expect(config.openAtLogin == false)
        #expect(Configuration().openAtLogin == nil)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("alex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try PropertyListSerialization.data(fromPropertyList: ["ShowInMenuBar": true], format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("alex/uk.street365.decant.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["ShowInMenuBar": false], format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("uk.street365.decant.plist"))
        let loader = ConfigurationLoader(managedPreferencesDirectory: dir.path, requireRootOwnership: false)
        #expect(loader.load(userName: "alex").0.showInMenuBar == false)
    }

    @Test func logPathDefaultsPerUser() {
        var config = Configuration()
        #expect(config.effectiveLogFilePath(isRoot: true) == "/Library/Logs/decant.log")
        #expect(config.effectiveLogFilePath(isRoot: false).hasSuffix("/Library/Logs/decant.log"))
        #expect(config.effectiveLogFilePath(isRoot: false) != "/Library/Logs/decant.log")
        config.logFilePath = "/tmp/x.log"
        #expect(config.effectiveLogFilePath(isRoot: true) == "/tmp/x.log")
    }

    @Test func onlyPendingDryRunsOfferInstall() {
        func report(_ action: InstallReport.Action, _ code: Int32 = 0) -> InstallReport {
            InstallReport(action: action, exitCode: code, message: "", diskImage: "x.dmg")
        }
        #expect(report(.wouldInstall).canInstall)
        #expect(report(.wouldUpdate).canInstall)
        #expect(!report(.unchanged).canInstall)
        #expect(!report(.failed, ExitStatus.gatekeeperRejected.rawValue).canInstall)
        #expect(!report(.failed, ExitStatus.gatekeeperRejected.rawValue).succeeded)
    }

    @Test func missingImageFailsCheck() {
        // A missing image fails the dry run cleanly rather than crashing the app.
        let (report, _) = InteractiveInstall.run(
            diskImage: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).dmg"), dryRun: true,
            loader: ConfigurationLoader(managedPreferencesDirectory: "/nonexistent", requireRootOwnership: false))
        #expect(report.exitCode == ExitStatus.diskImageError.rawValue)
        #expect(!report.canInstall)
    }
}
