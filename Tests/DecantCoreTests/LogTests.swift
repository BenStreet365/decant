import Foundation
import Testing
@testable import DecantCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LogTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct LogTests {
    @Test func defaultCapIsTenMegabytes() {
        #expect(Log().maxFileSize == 10 * 1024 * 1024)
    }

    @Test func fileStaysUnderCapAndKeepsNewestLines() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("decant.log").path

        let log = Log()
        log.quiet = true
        log.maxFileSize = 4096
        log.attachFile(at: path)
        for i in 0..<500 { log.info("line \(i)") }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.count <= 4096)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(lines.first?.hasSuffix("Log trimmed to stay under 4096 bytes") == true)
        #expect(lines.last?.hasSuffix("INFO line 499") == true)
        // Every kept line is whole.
        #expect(lines.dropFirst().allSatisfy { $0.contains(" INFO line ") })
    }

    @Test func oversizedExistingFileIsTrimmedOnAttach() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("decant.log")
        try Data(String(repeating: "old line\n", count: 1000).utf8).write(to: url)

        let log = Log()
        log.quiet = true
        log.maxFileSize = 1000
        log.attachFile(at: url.path)

        #expect(try Data(contentsOf: url).count <= 1000)
    }

    @Test func symlinkedLogFileIsNotFollowed() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        try Data("untouched\n".utf8).write(to: target)
        let link = dir.appendingPathComponent("decant.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let log = Log()
        log.quiet = true
        log.attachFile(at: link.path)
        log.info("should not be written")

        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched\n")
    }
}
