import AppKit
import DecantCore
import Observation
import UniformTypeIdentifiers

/// One disk image at a time: check it (a dry run with every install check), then install it on
/// the user's request, then offer to move it to the Trash.
@MainActor @Observable
final class InstallModel {
    enum Phase {
        case empty
        /// The dropped file is not something Decant can open.
        case invalid(String)
        case checking(URL)
        /// The dry run's result. `report.canInstall` says whether Install is offered.
        case checked(URL, InstallReport, Configuration)
        case installing(URL, InstallReport)
        case finished(URL, InstallReport)
    }

    enum TrashState: Equatable {
        case offered, trashed, kept
        case failed(String)
    }

    private(set) var phase: Phase = .empty
    var trash: TrashState = .offered

    var isBusy: Bool {
        switch phase {
        case .checking, .installing: true
        default: false
        }
    }

    /// The disk image whose work is done and may be offered for the Trash.
    var finishedDiskImage: URL? {
        switch phase {
        case .finished(let url, let report) where report.succeeded: url
        case .checked(let url, let report, _) where report.action == .unchanged: url
        default: nil
        }
    }

    static func isDiskImage(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .diskImage)
        }
        return url.pathExtension.lowercased() == "dmg"
    }

    func open(_ url: URL) {
        guard !isBusy else { return }
        guard url.isFileURL, Self.isDiskImage(url) else {
            phase = .invalid("\(url.lastPathComponent) is not a disk image.")
            return
        }
        trash = .offered
        phase = .checking(url)
        Task {
            let (report, config) = await Task.detached { InteractiveInstall.run(diskImage: url, dryRun: true) }.value
            phase = .checked(url, report, config)
        }
    }

    func install() {
        guard case .checked(let url, let check, _) = phase, check.canInstall else { return }
        phase = .installing(url, check)
        Task {
            let (report, _) = await Task.detached { InteractiveInstall.run(diskImage: url, dryRun: false, matching: check) }.value
            phase = .finished(url, report)
        }
    }

    func reset() {
        guard !isBusy else { return }
        phase = .empty
    }

    func moveDiskImageToTrash() {
        guard let url = finishedDiskImage else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            trash = .trashed
        } catch {
            trash = .failed(error.localizedDescription)
        }
    }

    func chooseDiskImage() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Disk Image"
        panel.prompt = "Check"
        panel.allowedContentTypes = [.diskImage]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }
}
