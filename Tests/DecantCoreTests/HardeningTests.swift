import Foundation
import Security
import Testing
@testable import DecantCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("HardeningTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct PathSafetyTests {
    @Test func systemFilesAreSafe() {
        #expect(PathSafety.problem(with: "/usr/bin/true") == nil)
        // /tmp is a root-owned symlink to /private/tmp, which is sticky.
        #expect(PathSafety.problem(with: "/tmp") == nil)
    }

    @Test func userOwnedPathsAreNotSafeForRoot() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("decant")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        #expect(PathSafety.problem(with: file.path)?.contains("owned by uid \(getuid())") == true)
        #expect(PathSafety.problem(with: file.path, trustedOwners: [0, getuid()]) == nil)
        #expect(PathSafety.problem(with: dir.appendingPathComponent("missing").path) != nil)
    }

    @Test func writableFoldersAreNotSafe() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let me: Set<uid_t> = [0, getuid()]
        let inner = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
        let file = inner.appendingPathComponent("decant")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        chmod(inner.path, 0o777)
        #expect(PathSafety.problem(with: file.path, trustedOwners: me)?.contains("writable by everyone") == true)
        // Sticky, like /tmp: others cannot rename or remove what they do not own.
        chmod(inner.path, 0o1777)
        #expect(PathSafety.problem(with: file.path, trustedOwners: me) == nil)
        // Group-writable for an ordinary group (staff).
        chown(inner.path, getuid(), 20)
        chmod(inner.path, 0o775)
        #expect(PathSafety.problem(with: file.path, trustedOwners: me)?.contains("writable by group 20") == true)
    }

    @Test func symlinkTargetsAreChecked() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = dir.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        chmod(shared.path, 0o777)
        let file = shared.appendingPathComponent("decant")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let link = dir.appendingPathComponent("decant")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(PathSafety.problem(with: link.path, trustedOwners: [0, getuid()])?.contains("writable by everyone") == true)
    }
}

@Suite struct LogHardLinkTests {
    @Test func hardLinkedLogFileIsNotWritten() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("sudoers")
        try Data("untouched\n".utf8).write(to: target)
        let link = dir.appendingPathComponent("decant.log")
        #expect(Darwin.link(target.path, link.path) == 0)

        let log = Log()
        log.quiet = true
        log.maxFileSize = 10
        log.attachFile(at: link.path)
        log.info("should not be written")

        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched\n")
    }

    @Test func logLinesStayOnOneLine() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("decant.log").path
        let log = Log()
        log.quiet = true
        log.attachFile(at: path)
        log.info("Found Evil\nRESULT installed exit=0: fake.app")

        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].hasSuffix("INFO Found Evil\\nRESULT installed exit=0: fake.app"))
    }

    @Test func controlCharactersAreEscaped() {
        #expect("plain name.app".escapingControlCharacters == "plain name.app")
        #expect("a\nb\tc\r".escapingControlCharacters == "a\\nb\\tc\\r")
        #expect("x\u{1B}[31my\u{2028}z".escapingControlCharacters == "x\\u{1B}[31my\\u{2028}z")
        #expect("Café ☕️".containsControlCharacters == false)
        #expect("a\u{0}b".containsControlCharacters)
    }
}

/// Bundles on a disk image are read as root before their signature is checked.
@Suite struct BundleReadingTests {
    func expectRejected(_ app: URL, _ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try AppBundle(url: app)
            Issue.record("Expected \(app.lastPathComponent) to be rejected", sourceLocation: sourceLocation)
        } catch let error as DecantError {
            #expect(error.status == .unsupportedLayout, sourceLocation: sourceLocation)
            #expect(error.message.contains(text), "\(error.message)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    func replace(_ item: URL, with make: (URL) throws -> Void) throws {
        try FileManager.default.removeItem(at: item)
        try make(item)
    }

    @Test func plainBundleIsRead() throws {
        let v = try FakeVolume()
        let app = try AppBundle(url: try v.app("Example.app", version: "1.2"))
        #expect(app.bundleIdentifier == "com.example.app" && app.shortVersion == "1.2")
    }

    @Test func fifoInfoPlistDoesNotHang() throws {
        let v = try FakeVolume()
        let app = try v.app("Example.app")
        try replace(app.appendingPathComponent("Contents/Info.plist")) { #expect(mkfifo($0.path, 0o644) == 0) }
        expectRejected(app, "not a regular file")
    }

    @Test func symlinksInsideTheBundleAreNotFollowed() throws {
        let v = try FakeVolume()
        let outside = try v.app("Outside.app")

        let plistLink = try v.app("PlistLink.app")
        try replace(plistLink.appendingPathComponent("Contents/Info.plist")) {
            try FileManager.default.createSymbolicLink(at: $0, withDestinationURL: outside.appendingPathComponent("Contents/Info.plist"))
        }
        expectRejected(plistLink, "no readable Contents/Info.plist")

        let contentsLink = v.url.appendingPathComponent("ContentsLink.app")
        try FileManager.default.createDirectory(at: contentsLink, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: contentsLink.appendingPathComponent("Contents"),
                                                   withDestinationURL: outside.appendingPathComponent("Contents"))
        expectRejected(contentsLink, "no readable Contents/Info.plist")

        let executableLink = try v.app("ExecutableLink.app")
        try replace(executableLink.appendingPathComponent("Contents/MacOS/Main")) {
            try FileManager.default.createSymbolicLink(atPath: $0.path, withDestinationPath: "/bin/sh")
        }
        expectRejected(executableLink, "missing its executable")
    }

    @Test func oversizedInfoPlistIsRefused() throws {
        let v = try FakeVolume()
        let app = try v.app("Example.app")
        let plist = app.appendingPathComponent("Contents/Info.plist")
        #expect(truncate(plist.path, off_t(AppBundle.maxInfoPlistSize + 1)) == 0)
        expectRejected(app, "larger than")
    }

    @Test func controlCharactersAreRefused() throws {
        let v = try FakeVolume()
        expectRejected(try v.app("Evil\nsource=Notarized Developer ID\n.app"), "control characters in its name")
        expectRejected(try v.app("Example.app", id: "com.example\nRESULT installed"), "control characters in its Info.plist")
        expectRejected(try v.app("Version.app", version: "1.0\u{1B}[2K"), "control characters in its Info.plist")
    }
}

@Suite struct TeamIDVerificationTests {
    @Test func teamIDNeedsApplesBacking() {
        let devID: Set<SigningState> = [.developerID]
        #expect(CodeSignature.verifiedTeamID(claimed: "ABCDE12345", isAdHoc: false, leafCertificateMatches: true, states: devID) == "ABCDE12345")
        // A self-signed certificate can claim any Team ID.
        #expect(CodeSignature.verifiedTeamID(claimed: "ABCDE12345", isAdHoc: false, leafCertificateMatches: false, states: []) == nil)
        // Apple signs Mac App Store apps, so their Team ID is Apple's word.
        #expect(CodeSignature.verifiedTeamID(claimed: "ABCDE12345", isAdHoc: false, leafCertificateMatches: false, states: [.appStore]) == "ABCDE12345")
        #expect(CodeSignature.verifiedTeamID(claimed: "ABCDE12345", isAdHoc: true, leafCertificateMatches: true, states: devID) == nil)
        #expect(CodeSignature.verifiedTeamID(claimed: nil, isAdHoc: false, leafCertificateMatches: false, states: devID) == nil)
    }

    @Test func teamRequirementCompiles() throws {
        var requirement: SecRequirement?
        let text = try #require(CodeSignature.teamRequirement("ABCDE12345"))
        #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
        // Not a Team ID, and must not be able to change the requirement's meaning.
        #expect(CodeSignature.teamRequirement("X\" or anchor trusted") == nil)
        #expect(CodeSignature.teamRequirement("") == nil)
    }

    @Test func appleSoftwareHasNoUnverifiedTeam() throws {
        let info = try CodeSignature.inspect(URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        #expect(info.states.contains(.apple))
        #expect(info.unverifiedTeamID == nil)
    }
}

@Suite struct PackageVersionTests {
    @Test func readsVersionFromPackageInfo() {
        let info = #"<?xml version="1.0" encoding="utf-8"?><pkg-info format-version="2" identifier="uk.street365.decant" version="0.4.0" install-location="/" auth="root"><payload numberOfFiles="3" installKBytes="100"/></pkg-info>"#
        #expect(Updater.packageVersion(fromPackageInfo: Data(info.utf8)) == "0.4.0")
        let other = info.replacingOccurrences(of: "uk.street365.decant", with: "com.example.other")
        #expect(Updater.packageVersion(fromPackageInfo: Data(other.utf8)) == nil)
        #expect(Updater.packageVersion(fromPackageInfo: Data("not xml".utf8)) == nil)
    }

    @Test func readsVersionFromRealPackage() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        FileManager.default.createFile(atPath: root.appendingPathComponent("file").path, contents: Data("x".utf8))
        let package = dir.appendingPathComponent("decant-full-0.4.0.pkg")
        let build = try Command.run("/usr/bin/pkgbuild", ["--root", root.path, "--identifier", "uk.street365.decant", "--version", "0.4.0",
                                                          "--install-location", "/tmp/decant-test", package.path])
        #expect(build.status == 0, "\(build.stderrString)")
        #expect(try Updater.packageVersion(of: package) == "0.4.0")

        let updater = Updater(config: Configuration(), log: Log(), currentVersion: "0.3.0")
        func release(_ version: String) -> Release {
            Release(version: version, publishedAt: Date(), packageURL: package, checksumURL: package)
        }
        #expect(throws: Never.self) { try updater.verifyPackageVersion(package, release: release("0.4.0")) }
        // An old package published under a newer tag.
        #expect(throws: DecantError.self) { try updater.verifyPackageVersion(package, release: release("0.9.0")) }
        let newer = Updater(config: Configuration(), log: Log(), currentVersion: "0.5.0")
        #expect(throws: DecantError.self) { try newer.verifyPackageVersion(package, release: release("0.4.0")) }
    }
}
