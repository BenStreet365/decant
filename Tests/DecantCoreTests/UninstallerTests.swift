import Foundation
import Testing
@testable import DecantCore

@Suite struct UninstallerTests {
    @Test func removesUserItemsAndNothingElse() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        let temp = fm.temporaryDirectory.appendingPathComponent("tmp-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: home)
            try? fm.removeItem(at: temp)
        }
        for item in Uninstaller.userItems {
            let url = home.appendingPathComponent(item)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data().write(to: temp.appendingPathComponent("uk.street365.decant.lock"))
        let installed = home.appendingPathComponent("Applications/Foo.app/Contents")
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        let otherLog = home.appendingPathComponent("Library/Logs/other.log")
        try Data().write(to: otherLog)

        let removed = try Uninstaller.removeUserItems(home: home, temporaryDirectory: temp)
        #expect(removed.count == Uninstaller.userItems.count + 1)
        for item in Uninstaller.userItems {
            #expect(!fm.fileExists(atPath: home.appendingPathComponent(item).path))
        }
        #expect(!fm.fileExists(atPath: temp.appendingPathComponent("uk.street365.decant.lock").path))
        #expect(fm.fileExists(atPath: installed.path))
        #expect(fm.fileExists(atPath: otherLog.path))

        // Nothing left: a second run removes nothing and does not fail.
        #expect(try Uninstaller.removeUserItems(home: home, temporaryDirectory: temp).isEmpty)
    }

    @Test func doesNotFollowSymlinks() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        let target = fm.temporaryDirectory.appendingPathComponent("target-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: home)
            try? fm.removeItem(at: target)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("file"))
        let caches = home.appendingPathComponent("Library/Caches")
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: caches.appendingPathComponent(Uninstaller.appBundleIdentifier), withDestinationURL: target)

        _ = try Uninstaller.removeUserItems(home: home, temporaryDirectory: nil)
        #expect(fm.fileExists(atPath: target.appendingPathComponent("file").path))
    }

    @Test func refusedWithoutRoot() {
        let log = Log()
        log.quiet = true
        let uninstaller = Uninstaller(config: Configuration(), log: log)
        uninstaller.effectiveUID = 501
        let report = uninstaller.uninstall(dryRun: true)
        #expect(report.exitCode == ExitStatus.notAuthorized.rawValue)
        #expect(report.removed.isEmpty)
    }

    @Test func userTemporaryDirectoryIsPerUser() {
        let dir = Uninstaller.userTemporaryDirectory()
        #expect(dir != nil)
        #expect(dir?.path.hasPrefix("/") == true)
    }
}
