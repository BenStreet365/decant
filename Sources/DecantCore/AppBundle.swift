import Darwin
import Foundation

public struct AppBundle: Sendable {
    public let url: URL
    public let bundleIdentifier: String
    public let shortVersion: String?
    public let buildVersion: String?
    public let executableName: String

    public var name: String { url.lastPathComponent }
    public var executableURL: URL { url.appendingPathComponent("Contents/MacOS/\(executableName)") }
    public var displayVersion: String { Self.displayVersion(short: shortVersion, build: buildVersion) }

    public static func displayVersion(short: String?, build: String?) -> String {
        switch (short, build) {
        case let (s?, b?) where s != b: "\(s) (\(b))"
        case let (s?, _): s
        case let (nil, b?): b
        default: "unknown"
        }
    }

    /// Reads Contents/Info.plist directly (Bundle caches by path, which is wrong across updates).
    /// Nothing inside the bundle is followed through a symlink, and Info.plist must be a regular
    /// file of reasonable size: this runs as root on a disk image that has not been verified yet,
    /// where a FIFO would hang the install and a symlink would read files outside the image.
    public init(url: URL) throws {
        self.url = url
        let name = url.lastPathComponent.escapingControlCharacters
        guard !url.lastPathComponent.containsControlCharacters else {
            throw DecantError(.unsupportedLayout, "\(name) has control characters in its name")
        }
        let data = try Self.readInfoPlist(of: url)
        guard let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw DecantError(.unsupportedLayout, "\(name) has no readable Contents/Info.plist")
        }
        guard let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            throw DecantError(.unsupportedLayout, "\(name) has no CFBundleIdentifier")
        }
        if let type = info["CFBundlePackageType"] as? String, type != "APPL" {
            throw DecantError(.unsupportedLayout, "\(name) is not an application bundle (CFBundlePackageType \(type.escapingControlCharacters))")
        }
        guard let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              !executable.contains("/"), executable != ".", executable != ".." else {
            throw DecantError(.unsupportedLayout, "\(name) has no valid CFBundleExecutable")
        }
        let shortVersion = info["CFBundleShortVersionString"] as? String
        let buildVersion = info["CFBundleVersion"] as? String
        // These end up in logs, the RESULT line and spctl's output, which is parsed line by line.
        guard ![identifier, executable, shortVersion ?? "", buildVersion ?? ""].contains(where: \.containsControlCharacters) else {
            throw DecantError(.unsupportedLayout, "\(name) has control characters in its Info.plist")
        }
        bundleIdentifier = identifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        executableName = executable
        guard Self.isExecutable(executable, in: url) else {
            throw DecantError(.unsupportedLayout, "\(name) is missing its executable \(executable)")
        }
    }

    static let maxInfoPlistSize = 4 * 1024 * 1024

    static func readInfoPlist(of bundle: URL) throws -> Data {
        let name = bundle.lastPathComponent.escapingControlCharacters
        // O_NONBLOCK: opening a FIFO for reading would otherwise wait for a writer forever.
        let fd = openWithoutSymlinks(["Contents", "Info.plist"], in: bundle, flags: O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            throw DecantError(.unsupportedLayout, "\(name) has no readable Contents/Info.plist (\(String(cString: strerror(errno))))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw DecantError(.unsupportedLayout, "\(name)'s Contents/Info.plist is not a regular file")
        }
        guard st.st_size <= maxInfoPlistSize else {
            throw DecantError(.unsupportedLayout, "\(name)'s Contents/Info.plist is larger than \(maxInfoPlistSize) bytes")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw DecantError(.unsupportedLayout, "Cannot read \(name)'s Contents/Info.plist: \(String(cString: strerror(errno)))")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maxInfoPlistSize else {
                throw DecantError(.unsupportedLayout, "\(name)'s Contents/Info.plist is larger than \(maxInfoPlistSize) bytes")
            }
        }
        return data
    }

    /// The main executable is a regular file (not a symlink) with an execute bit set.
    static func isExecutable(_ executable: String, in bundle: URL) -> Bool {
        let fd = openWithoutSymlinks(["Contents", "MacOS"], in: bundle, flags: O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        return fstatat(fd, executable, &st, AT_SYMLINK_NOFOLLOW) == 0
            && (st.st_mode & S_IFMT) == S_IFREG && st.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
    }

    /// Opens `components` below `bundle` one at a time, never following a symlink, and returns a
    /// descriptor for the last one (opened with `flags`), or -1 with errno set.
    static func openWithoutSymlinks(_ components: [String], in bundle: URL, flags: Int32) -> Int32 {
        var fd = open(bundle.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        for (index, component) in components.enumerated() where fd >= 0 {
            let isLast = index == components.count - 1
            let next = openat(fd, component, (isLast ? flags : O_RDONLY | O_DIRECTORY) | O_NOFOLLOW | O_CLOEXEC)
            let saved = errno
            close(fd)
            errno = saved
            fd = next
        }
        return fd
    }

    /// Orders by CFBundleShortVersionString, then CFBundleVersion. Returns nil if neither
    /// bundle has comparable version information.
    public static func compareVersions(_ lhs: AppBundle, _ rhs: AppBundle) -> ComparisonResult? {
        compareVersions(short: (lhs.shortVersion, rhs.shortVersion), build: (lhs.buildVersion, rhs.buildVersion))
    }

    public static func compareVersions(short: (String?, String?), build: (String?, String?)) -> ComparisonResult? {
        var compared = false
        if let a = short.0, let b = short.1 {
            compared = true
            let result = compareVersionStrings(a, b)
            if result != .orderedSame { return result }
        }
        if let a = build.0, let b = build.1 {
            compared = true
            let result = compareVersionStrings(a, b)
            if result != .orderedSame { return result }
        }
        return compared ? .orderedSame : nil
    }

    /// Numeric, component-wise comparison: "1.10" > "1.9", "2.0" == "2", "1.0b2" > "1.0b1".
    public static func compareVersionStrings(_ a: String, _ b: String) -> ComparisonResult {
        let separators = CharacterSet(charactersIn: ".-_ ")
        var left = a.components(separatedBy: separators).filter { !$0.isEmpty }
        var right = b.components(separatedBy: separators).filter { !$0.isEmpty }
        let count = max(left.count, right.count)
        left += Array(repeating: "0", count: count - left.count)
        right += Array(repeating: "0", count: count - right.count)
        for (l, r) in zip(left, right) {
            let result = l.compare(r, options: [.numeric, .caseInsensitive])
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }
}
