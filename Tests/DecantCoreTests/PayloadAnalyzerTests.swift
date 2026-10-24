import Foundation
import Testing
@testable import DecantCore

/// Builds fake mounted volumes in a temporary directory.
final class FakeVolume {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("vol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func app(_ name: String, id: String = "com.example.app", version: String = "1.0") throws -> URL {
        let app = url.appendingPathComponent(name)
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "Main", "CFBundlePackageType": "APPL",
                                   "CFBundleShortVersionString": version, "CFBundleVersion": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let exe = macOS.appendingPathComponent("Main")
        FileManager.default.createFile(atPath: exe.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        return app
    }

    func file(_ name: String, executable: Bool = false) {
        FileManager.default.createFile(atPath: url.appendingPathComponent(name).path, contents: Data("x".utf8),
                                       attributes: [.posixPermissions: executable ? 0o755 : 0o644])
    }

    func folder(_ name: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    func symlink(_ name: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url.appendingPathComponent(name).path, withDestinationPath: target)
    }
}

private func expectUnsupported(_ volumes: [URL], containing text: String) {
    do {
        _ = try PayloadAnalyzer.analyze(volumes: volumes)
        Issue.record("Expected unsupported layout")
    } catch let error as DecantError {
        #expect(error.status == .unsupportedLayout)
        #expect(error.message.localizedCaseInsensitiveContains(text), "\(error.message)")
    } catch {
        Issue.record("Unexpected error \(error)")
    }
}

@Suite struct PayloadAnalyzerTests {
    @Test func classicDragAndDropImage() throws {
        let v = try FakeVolume()
        try v.app("Example.app")
        try v.symlink("Applications", to: "/Applications")
        try v.folder(".background")
        v.file(".DS_Store")
        v.file(".VolumeIcon.icns")
        v.file("Read Me.rtf")
        v.file("LICENSE")
        let result = try PayloadAnalyzer.analyze(volumes: [v.url])
        #expect(result.app.lastPathComponent == "Example.app")
    }

    @Test func finderAliasToApplicationsIsIgnored() throws {
        let v = try FakeVolume()
        try v.app("Example.app")
        v.file("Applications")
        #expect(try PayloadAnalyzer.analyze(volumes: [v.url]).app.lastPathComponent == "Example.app")
    }

    @Test func packageImagesAreRefused() throws {
        let v = try FakeVolume()
        v.file("Example.pkg")
        expectUnsupported([v.url], containing: "installer package")

        let bundlePkg = try FakeVolume()
        try bundlePkg.app("Example.app")
        try bundlePkg.folder("Extras.mpkg")
        expectUnsupported([bundlePkg.url], containing: "installer package")
    }

    @Test func installerAppsAreRefused() throws {
        let named = try FakeVolume()
        try named.app("Install Example.app")
        expectUnsupported([named.url], containing: "installer")

        let byID = try FakeVolume()
        try byID.app("Example Setup.app", id: "com.example.installer")
        expectUnsupported([byID.url], containing: "installer")

        let uninstall = try FakeVolume()
        try uninstall.app("Uninstall Example.app")
        expectUnsupported([uninstall.url], containing: "uninstaller")
    }

    @Test func multipleAppsAreRefused() throws {
        let v = try FakeVolume()
        try v.app("One.app", id: "com.example.one")
        try v.app("Two.app", id: "com.example.two")
        expectUnsupported([v.url], containing: "several applications")
    }

    @Test func extraFoldersAndScriptsAreRefused() throws {
        let folder = try FakeVolume()
        try folder.app("Example.app")
        try folder.folder("Plugins")
        expectUnsupported([folder.url], containing: "Plugins")

        let script = try FakeVolume()
        try script.app("Example.app")
        script.file("postinstall", executable: true)
        expectUnsupported([script.url], containing: "executable")

        let command = try FakeVolume()
        try command.app("Example.app")
        command.file("Setup.command")
        expectUnsupported([command.url], containing: "Setup.command")
    }

    @Test func emptyImageIsRefused() throws {
        let v = try FakeVolume()
        try v.symlink("Applications", to: "/Applications")
        expectUnsupported([v.url], containing: "does not contain an application")
    }

    @Test func symlinkedAppIsNotFollowed() throws {
        let v = try FakeVolume()
        try v.symlink("Sneaky.app", to: "/System/Applications/Chess.app")
        expectUnsupported([v.url], containing: "does not contain an application")
    }

    @Test func appBundleValidation() throws {
        let v = try FakeVolume()
        let app = try v.app("Example.app", version: "2.1")
        let bundle = try AppBundle(url: app)
        #expect(bundle.bundleIdentifier == "com.example.app")
        #expect(bundle.displayVersion == "2.1")

        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/MacOS/Main"))
        #expect(throws: DecantError.self) { try AppBundle(url: app) }
    }
}

@Suite struct VersionTests {
    @Test(arguments: [
        ("1.10", "1.9", ComparisonResult.orderedDescending),
        ("2.0", "2", .orderedSame),
        ("2.0.1", "2.0", .orderedDescending),
        ("1.0b2", "1.0b10", .orderedAscending),
        ("10.0", "9.9.9", .orderedDescending),
    ])
    func compare(_ a: String, _ b: String, _ expected: ComparisonResult) {
        #expect(AppBundle.compareVersionStrings(a, b) == expected)
    }

    @Test func buildVersionBreaksTies() {
        #expect(AppBundle.compareVersions(short: ("1.0", "1.0"), build: ("101", "100")) == .orderedDescending)
        #expect(AppBundle.compareVersions(short: (nil, nil), build: (nil, nil)) == nil)
    }
}
