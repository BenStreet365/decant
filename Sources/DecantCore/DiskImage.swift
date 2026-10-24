import Foundation

/// A disk image attached read-only, without Finder windows, at a private random mount point.
public final class DiskImage {
    public let volumes: [URL]
    private let devices: [String]
    private let mountRoot: URL
    private let log: Log
    private var detached = false

    static let hdiutil = "/usr/bin/hdiutil"
    static let diskutil = "/usr/sbin/diskutil"
    static let mountRootPrefix = "decant-mount-"

    /// Checks image properties that would otherwise make diskutil prompt the user.
    public static func preflight(_ path: String, acceptLicense: Bool) throws {
        // `diskutil image info` asks for the passphrase, so ask hdiutil, which only reports it.
        let encrypted = try Command.run(hdiutil, ["isencrypted", "-plist", path])
        if encrypted.status == 0,
           let dict = try? PropertyListSerialization.propertyList(from: encrypted.stdout, format: nil) as? [String: Any],
           dict["encrypted"] as? Bool == true {
            throw DecantError(.unsupportedLayout, "The disk image is encrypted and would need a password")
        } else if encrypted.status != 0 {
            throw DecantError(.diskImageError, "Cannot read disk image \(path): \(encrypted.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // `diskutil image info` shows the licence and waits for an answer, so read it from the image.
        if try hasLicenseAgreement(path), !acceptLicense {
            throw DecantError(.unsupportedLayout, "The disk image has a licence agreement; set AcceptLicenseAgreements to accept it on the user's behalf")
        }
    }

    /// Whether a UDIF image carries a licence agreement: an `LPic` resource in the XML property
    /// list that the 512-byte `koly` trailer points to. Other image formats cannot carry one.
    static func hasLicenseAgreement(_ path: String) throws -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw DecantError(.diskImageError, "Cannot open disk image \(path)")
        }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 512 else { return false }
        try handle.seek(toOffset: size - 512)
        guard let trailer = try handle.read(upToCount: 512), trailer.count == 512,
              trailer.prefix(4) == Data("koly".utf8) else { return false }
        func uint64(at offset: Int) -> UInt64 {
            trailer[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
        }
        let xmlOffset = uint64(at: 0xD8), xmlLength = uint64(at: 0xE0)
        guard xmlLength > 0, xmlLength <= 64 << 20, xmlOffset <= size - 512 - xmlLength else {
            return false
        }
        try handle.seek(toOffset: xmlOffset)
        guard let xml = try handle.read(upToCount: Int(xmlLength)),
              let dict = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let resources = dict["resource-fork"] as? [String: Any] else {
            throw DecantError(.diskImageError, "Cannot read the resources of disk image \(path)")
        }
        return (resources["LPic"] as? [Any])?.isEmpty == false
    }

    public init(attaching path: String, log: Log) throws {
        self.log = log
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.mountRootPrefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        mountRoot = root

        Self.ejectLeftovers(except: root, log: log)
        let entities: [Entity]
        do {
            entities = try Self.attach(path)
            // diskutil may hand back an attachment someone else made, mounts and all. Don't use
            // it, and don't eject it.
            let mounted = entities.compactMap(\.mountPoint)
            guard mounted.isEmpty else {
                throw DecantError(.diskImageError, "The disk image is already open at \(mounted.joined(separator: ", ")); eject it and try again")
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        devices = Self.wholeDisks(entities)

        // Mount each file system ourselves: `--mountPoint` on attach only works for images with
        // a single volume.
        var mountPoints: [URL] = []
        var failure: DecantError?
        for (index, entity) in entities.enumerated() where entity.fileSystem != nil {
            let mountPoint = root.appendingPathComponent("\(index)")
            do {
                try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let result = try Command.run(Self.diskutil, [
                    "mount", "readOnly", "nobrowse", "-mountOptions", "nosuid,nodev", "-mountPoint", mountPoint.path, entity.device,
                ])
                guard result.status == 0 else {
                    throw DecantError(.diskImageError, "Could not mount \(entity.device) from the disk image: \(Self.message(result))")
                }
                mountPoints.append(mountPoint)
            } catch {
                failure = error as? DecantError ?? DecantError(.diskImageError, error.localizedDescription)
                break
            }
        }
        volumes = mountPoints
        if let failure {
            detach()
            throw failure
        }
        if volumes.isEmpty {
            detach()
            throw DecantError(.unsupportedLayout, "The disk image has no mountable volume")
        }
        // diskutil was asked for nosuid,nodev; check it really mounted them that way, and there.
        for volume in volumes {
            var fs = statfs()
            guard statfs(volume.path, &fs) == 0,
                  Self.mountedOn(fs) == Self.realPath(volume.path),
                  fs.f_flags & UInt32(MNT_NOSUID) != 0, fs.f_flags & UInt32(MNT_NODEV) != 0,
                  fs.f_flags & UInt32(MNT_RDONLY) != 0 else {
                detach()
                throw DecantError(.diskImageError, "\(volume.path) is not mounted read-only,nosuid,nodev; refusing to use it")
            }
        }
        log.debug("Attached \(path) at \(volumes.map(\.path).joined(separator: ", "))")
    }

    /// One device from `diskutil image attach --plist` (or `hdiutil attach -plist`).
    struct Entity: Equatable {
        var device: String
        var fileSystem: String? = nil
        var mountPoint: String? = nil
    }

    /// Attaches without mounting. "Y" answers a licence prompt; it is only reached when
    /// preflight allowed it.
    static func attach(_ path: String) throws -> [Entity] {
        let input = Data(String(repeating: "Y\n", count: 4).utf8)
        var tool = "diskutil image attach"
        var result = try Command.run(
            diskutil,
            ["image", "attach", "--plist", "--readOnly", "--nobrowse", "--noMount", path],
            input: input,
            environment: ["PAGER": "/bin/cat"]
        )
        // 64 is a usage error: a macOS whose diskutil lacks one of these options. hdiutil
        // attaches the same way there.
        if result.status == 64 {
            tool = "hdiutil attach"
            result = try Command.run(
                hdiutil,
                ["attach", path, "-plist", "-readonly", "-nobrowse", "-noautoopen", "-nomount"],
                input: input,
                environment: ["PAGER": "/bin/cat"]
            )
        }
        guard result.status == 0 else {
            throw DecantError(.diskImageError, "Could not attach the disk image: \(message(result))")
        }
        guard let entities = parseAttach(result.stdout) else {
            throw DecantError(.diskImageError, "Unexpected output from \(tool)")
        }
        return entities
    }

    static func parseAttach(_ output: Data) -> [Entity]? {
        // Licence text may precede the plist on stdout.
        var plistData = output
        if let start = plistData.range(of: Data("<?xml".utf8)) {
            plistData = plistData.subdata(in: start.lowerBound..<plistData.endIndex)
        }
        guard let dict = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { entity in
            guard let device = entity["dev-entry"] as? String, !device.isEmpty else { return nil }
            let mountPoint = entity["mount-point"] as? String
            let fileSystem = entity["filesystem-type"] as? String ?? entity["volume-kind"] as? String
            return Entity(device: device, fileSystem: fileSystem,
                          mountPoint: mountPoint?.isEmpty == false ? mountPoint : nil)
        }
    }

    /// Ejecting the whole-disk devices ejects all of their partitions. APFS images also expose a
    /// synthesized whole disk for the container.
    static func wholeDisks(_ entities: [Entity]) -> [String] {
        entities.map { $0.device.hasPrefix("/dev/") ? String($0.device.dropFirst(5)) : $0.device }
            .filter { $0.wholeMatch(of: /disk[0-9]+/) != nil }
    }

    /// A mount point decant made (`decant-mount-*/…` in this user's temporary folder). Installs
    /// hold the install lock while they mount, and the lock covers the same folder, so a mount
    /// found there belongs to a run that has gone.
    static func isLeftoverMount(_ mountPoint: String) -> Bool {
        isLeftoverMount(mountPoint, temporaryDirectory: FileManager.default.temporaryDirectory)
    }

    static func isLeftoverMount(_ mountPoint: String, temporaryDirectory: URL) -> Bool {
        let parent = URL(fileURLWithPath: mountPoint).deletingLastPathComponent()
        guard parent.lastPathComponent.hasPrefix(mountRootPrefix) else { return false }
        // Mount points are reported with /private; the temporary folder is not.
        return realPath(parent.deletingLastPathComponent().path) == realPath(temporaryDirectory.path)
    }

    /// Ejects images left mounted by earlier runs that were killed before they could, which
    /// otherwise pile up, and removes their empty mount folders.
    static func ejectLeftovers(except current: URL, log: Log) {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        let leftovers = (0..<Int(max(count, 0))).compactMap { i -> (device: String, mountPoint: String)? in
            guard let fs = mounts?[i] else { return nil }
            let mountPoint = mountedOn(fs)
            let device = withUnsafeBytes(of: fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard device.hasPrefix("/dev/disk"), isLeftoverMount(mountPoint) else { return nil }
            return (String(device.dropFirst(5)), mountPoint)
        }
        for leftover in leftovers {
            log.info("Ejecting \(leftover.device) at \(leftover.mountPoint), left mounted by an earlier run")
            eject([leftover.device], log: log)
        }
        // rmdir, so nothing is removed from a volume that failed to eject.
        let temporary = FileManager.default.temporaryDirectory
        let roots = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in roots where name.hasPrefix(mountRootPrefix) && name != current.lastPathComponent {
            let root = temporary.appendingPathComponent(name)
            // Only folders decant made: not a symlink to somewhere else.
            var info = stat()
            guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { continue }
            for child in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                rmdir(root.appendingPathComponent(child).path)
            }
            rmdir(root.path)
        }
    }

    static func eject(_ devices: [String], log: Log) {
        for device in devices {
            // A synthesized disk goes away with the one it came from.
            guard FileManager.default.fileExists(atPath: "/dev/\(device)") else { continue }
            var result = try? Command.run(diskutil, ["eject", device])
            if result?.status != 0 {
                log.debug("Normal eject of \(device) failed, forcing")
                _ = try? Command.run(diskutil, ["unmountDisk", "force", device])
                result = try? Command.run(diskutil, ["eject", device])
                if result?.status != 0 { log.warning("Could not eject \(device)") }
            }
        }
    }

    /// Unlike `resolvingSymlinksInPath()`, keeps the /private that mount points are reported with.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func mountedOn(_ fs: statfs) -> String {
        withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func message(_ result: CommandResult) -> String {
        result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    public func detach() {
        guard !detached else { return }
        detached = true
        Self.eject(devices, log: log)
        try? FileManager.default.removeItem(at: mountRoot)
    }

    deinit { detach() }
}
