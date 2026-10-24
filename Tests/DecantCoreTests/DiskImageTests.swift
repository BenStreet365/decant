import Foundation
import Testing
@testable import DecantCore

@Suite struct DiskImageTests {
    private func plist(_ entities: [[String: Any]]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["system-entities": entities], format: .xml, options: 0)
    }

    @Test func parsesAttachOutputAfterLicenceText() throws {
        let output = Data("Licence text.\n".utf8) + (try plist([
            ["content-hint": "GUID_partition_scheme", "dev-entry": "disk5"],
            ["content-hint": "Apple_APFS", "dev-entry": "disk5s1"],
            ["content-hint": "Apple_APFS_Container", "dev-entry": "disk10"],
            ["content-hint": "Apple_APFS_Volume", "dev-entry": "disk10s1", "filesystem-type": "apfs"],
        ]))
        let entities = try #require(DiskImage.parseAttach(output))
        #expect(entities.map(\.device) == ["disk5", "disk5s1", "disk10", "disk10s1"])
        #expect(entities.filter { $0.fileSystem != nil }.map(\.device) == ["disk10s1"])
        #expect(entities.allSatisfy { $0.mountPoint == nil })
        #expect(DiskImage.parseAttach(Data("Error: busy".utf8)) == nil)
    }

    @Test func parsesHdiutilFallbackOutput() throws {
        let output = try plist([
            ["dev-entry": "/dev/disk5", "potentially-mountable": false],
            ["dev-entry": "/dev/disk10s1", "potentially-mountable": true, "volume-kind": "apfs"],
        ])
        let entities = try #require(DiskImage.parseAttach(output))
        #expect(entities == [DiskImage.Entity(device: "/dev/disk5"), DiskImage.Entity(device: "/dev/disk10s1", fileSystem: "apfs")])
        #expect(DiskImage.wholeDisks(entities) == ["disk5"])
    }

    @Test func reportsExistingMounts() throws {
        let output = try plist([["dev-entry": "disk5s1", "filesystem-type": "hfs", "mount-point": "/Volumes/App"]])
        #expect(DiskImage.parseAttach(output)?.first?.mountPoint == "/Volumes/App")
    }

    @Test func ejectsOnlyWholeDisks() {
        let entities = ["disk1", "disk10", "disk10s1", "/dev/disk12", "disk12s1s2"].map { DiskImage.Entity(device: $0) }
        #expect(DiskImage.wholeDisks(entities) == ["disk1", "disk10", "disk12"])
    }

    @Test func recognisesLeftoverMounts() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Mount points come back with /private in front of /var.
        let reported = DiskImage.realPath(temporary.path)
        #expect(DiskImage.isLeftoverMount("\(reported)/decant-mount-ABC/3", temporaryDirectory: temporary))
        #expect(DiskImage.isLeftoverMount("\(reported)/decant-mount-ABC/dmg.x1Y2", temporaryDirectory: temporary))
        #expect(!DiskImage.isLeftoverMount("\(reported)/other/3", temporaryDirectory: temporary))
        #expect(!DiskImage.isLeftoverMount("\(reported)/decant-mount-ABC/3/deeper", temporaryDirectory: temporary))
        #expect(!DiskImage.isLeftoverMount("/Volumes/decant-mount-ABC/3", temporaryDirectory: temporary))
        #expect(!DiskImage.isLeftoverMount("/Volumes/App", temporaryDirectory: temporary))
    }

    /// A UDIF image is its data, then the XML property list, then a 512-byte `koly` trailer
    /// that says where the property list is.
    private func udif(resources: [String: Any]) throws -> URL {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["resource-fork": resources], format: .xml, options: 0)
        var trailer = Data(count: 512)
        trailer.replaceSubrange(0..<4, with: Data("koly".utf8))
        func put(_ value: UInt64, at offset: Int) {
            trailer.replaceSubrange(offset..<offset + 8, with: withUnsafeBytes(of: value.bigEndian) { Data($0) })
        }
        let data = Data(repeating: 0, count: 1024)
        put(UInt64(data.count), at: 0xD8)
        put(UInt64(xml.count), at: 0xE0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dmg")
        try (data + xml + trailer).write(to: url)
        return url
    }

    @Test func findsLicenceAgreements() throws {
        let entry: [String: Any] = ["Attributes": "0x0000", "Data": Data([0, 0, 0, 1]), "ID": "5000", "Name": ""]
        let licensed = try udif(resources: ["blkx": [entry], "LPic": [entry]])
        let plain = try udif(resources: ["blkx": [entry]])
        let notUDIF = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).iso")
        try Data(repeating: 1, count: 4096).write(to: notUDIF)
        defer { for url in [licensed, plain, notUDIF] { try? FileManager.default.removeItem(at: url) } }

        #expect(try DiskImage.hasLicenseAgreement(licensed.path))
        #expect(try !DiskImage.hasLicenseAgreement(plain.path))
        #expect(try !DiskImage.hasLicenseAgreement(notUDIF.path))
        #expect(throws: DecantError.self) { try DiskImage.hasLicenseAgreement("/nonexistent/\(UUID().uuidString).dmg") }
    }
}
