import Foundation

/// Decides whether mounted disk image volumes hold a plain drag-and-drop app.
///
/// Accepted: exactly one `.app` bundle at the top level of the image, optionally alongside
/// hidden files (.background, .DS_Store, .VolumeIcon.icns ...), symlinks or Finder aliases
/// (the usual "Applications" shortcut) and plain documents (read-me, licence, web links).
///
/// Anything else - installer packages, installer apps, several apps, scripts, extra folders,
/// plug-ins - means the vendor expects more than a drag to Applications, so nothing is installed.
public enum PayloadAnalyzer {
    public static let documentExtensions: Set<String> = [
        "txt", "rtf", "rtfd", "pdf", "md", "markdown", "html", "htm", "webloc", "url", "inetloc",
        "png", "jpg", "jpeg", "gif", "tiff", "icns", "license", "licence",
    ]
    static let installerExtensions: Set<String> = ["pkg", "mpkg"]

    public struct Result: Sendable {
        public let app: URL
        public let ignored: [String]
    }

    public static func analyze(volumes: [URL]) throws -> Result {
        let fm = FileManager.default
        var apps: [URL] = []
        var ignored: [String] = []

        for volume in volumes {
            let entries: [String]
            do {
                entries = try fm.contentsOfDirectory(atPath: volume.path)
            } catch {
                throw DecantError(.diskImageError, "Cannot list \(volume.path): \(error.localizedDescription)")
            }

            for name in entries.sorted() {
                let url = volume.appendingPathComponent(name)
                switch try classify(url) {
                case .app: apps.append(url)
                case .ignore: ignored.append(name)
                case .unsupported(let reason): throw DecantError(.unsupportedLayout, reason)
                }
            }
        }

        guard !apps.isEmpty else {
            throw DecantError(.unsupportedLayout, "The disk image does not contain an application at its top level")
        }
        guard apps.count == 1 else {
            let names = apps.map(\.lastPathComponent).joined(separator: ", ")
            throw DecantError(.unsupportedLayout, "The disk image contains several applications (\(names)); refusing to guess")
        }

        let app = apps[0]
        if looksLikeInstaller(app) {
            throw DecantError(.unsupportedLayout, "\(app.lastPathComponent) looks like an installer or uninstaller, not a drag-and-drop app")
        }
        return Result(app: app, ignored: ignored)
    }

    enum Classification: Equatable {
        case app
        case ignore
        case unsupported(String)
    }

    static func classify(_ url: URL) throws -> Classification {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            return .unsupported("Cannot inspect \(name) in the disk image")
        }
        let type = st.st_mode & S_IFMT

        if name.hasPrefix(".") || name == "Icon\r" { return .ignore }
        // Symlinks (normally -> /Applications) are only shortcuts; never follow them.
        if type == S_IFLNK { return .ignore }

        if type == S_IFDIR {
            if ext == "app" { return .app }
            if ext == "rtfd" { return .ignore }
            if installerExtensions.contains(ext) {
                return .unsupported("\(name) is an installer package; this image needs an installer, not a drag-and-drop copy")
            }
            return .unsupported("The disk image contains an extra folder or bundle (\(name)) that may need installing separately")
        }

        guard type == S_IFREG else {
            return .unsupported("\(name) is not a regular file")
        }
        if installerExtensions.contains(ext) {
            return .unsupported("\(name) is an installer package; this image needs an installer, not a drag-and-drop copy")
        }
        if documentExtensions.contains(ext) { return .ignore }
        if ext.isEmpty {
            // Finder aliases ("Applications") and READMEs have no extension. Executables do not get a pass.
            if st.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 {
                return .unsupported("\(name) is an executable script or tool; this image needs extra steps")
            }
            return .ignore
        }
        return .unsupported("The disk image contains \(name), which suggests extra installation steps")
    }

    static func looksLikeInstaller(_ app: URL) -> Bool {
        let base = app.deletingPathExtension().lastPathComponent.lowercased()
        if base.hasPrefix("install ") || base.hasPrefix("uninstall") || base == "install" || base.contains("installer") {
            return true
        }
        if let bundle = try? AppBundle(url: app) {
            let id = bundle.bundleIdentifier.lowercased()
            if id.hasSuffix(".installer") || id.contains(".installer.") || id.hasSuffix(".uninstaller") {
                return true
            }
        }
        return false
    }
}
