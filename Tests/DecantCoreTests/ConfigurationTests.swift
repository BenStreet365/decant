import Foundation
import Testing
@testable import DecantCore

@Suite struct ConfigurationTests {
    @Test func defaultsAreLockedDown() {
        let config = Configuration()
        #expect(Configuration.domain == "uk.street365.decant")
        #expect(config.requireGatekeeperAssessment == true)
        #expect(config.runningAppBehavior == .skip)
        #expect(config.allowUserOption == false)
    }

    @Test func allowUserOptionOnlyFromDeviceProfile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("alex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try PropertyListSerialization.data(fromPropertyList: ["AllowUserOption": true], format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("alex/uk.street365.decant.plist"))

        let loader = ConfigurationLoader(managedPreferencesDirectory: dir.path, requireRootOwnership: false)
        let (userOnly, warnings) = loader.load(userName: "alex")
        #expect(!userOnly.allowUserOption)
        #expect(warnings.first?.contains("only honoured in the device profile") == true)

        try PropertyListSerialization.data(fromPropertyList: ["AllowUserOption": true], format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("uk.street365.decant.plist"))
        #expect(loader.load(userName: "alex").0.allowUserOption)
    }

    @Test func applyReadsKeysAndReportsBadTypes() {
        var config = Configuration()
        let warnings = config.apply([
            "RequireGatekeeperAssessment": false,
            "RunningAppBehavior": "terminate",
            "AllowedTeamIdentifiers": ["ABCDE12345", " "],
            "AllowDowngrade": "yes",
        ], source: "test")
        #expect(!config.requireGatekeeperAssessment)
        #expect(config.runningAppBehavior == .terminate)
        #expect(config.allowedTeamIdentifiers == ["ABCDE12345"])
        #expect(!config.allowDowngrade)
        #expect(warnings.count == 1)
    }

    @Test func deviceProfileOverridesUserProfile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("alex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func write(_ dict: [String: Any], to path: String) throws {
            try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
                .write(to: dir.appendingPathComponent(path))
        }
        try write(["AllowDowngrade": true, "RequireGatekeeperAssessment": false], to: "alex/uk.street365.decant.plist")
        try write(["RequireGatekeeperAssessment": true], to: "uk.street365.decant.plist")

        let loader = ConfigurationLoader(managedPreferencesDirectory: dir.path, requireRootOwnership: false)
        let (config, warnings) = loader.load(userName: "alex")
        #expect(warnings.isEmpty)
        #expect(config.allowDowngrade)
        #expect(config.requireGatekeeperAssessment)
        #expect(config.sources.count == 2)
    }

    @Test func untrustedFilesAreIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try PropertyListSerialization.data(fromPropertyList: ["RequireGatekeeperAssessment": false], format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("uk.street365.decant.plist"))

        // Written by the (non-root) test user, so it must not be trusted.
        let loader = ConfigurationLoader(managedPreferencesDirectory: dir.path, requireRootOwnership: true)
        let (config, warnings) = loader.load(userName: nil)
        #expect(config.requireGatekeeperAssessment)
        #expect(warnings.first?.contains("not owned by root") == true)
    }
}
