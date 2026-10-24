import AppKit
import DecantCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: InstallModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
        }
        .frame(width: 480, height: 400)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !model.isBusy else { return false }
            model.open(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .empty:
            DropZone(isTargeted: isTargeted, message: nil) { model.chooseDiskImage() }
        case .invalid(let message):
            DropZone(isTargeted: isTargeted, message: message) { model.chooseDiskImage() }
        case .checking(let url):
            Working(text: "Checking \(url.lastPathComponent)…")
        case .checked(let url, let report, let config):
            CheckedView(model: model, url: url, report: report, config: config)
        case .installing(_, let report):
            Working(text: "Installing \(report.app ?? "app")…")
        case .finished(_, let report):
            FinishedView(model: model, report: report)
        }
    }
}

private struct DropZone: View {
    let isTargeted: Bool
    let message: String?
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop a disk image here")
                .font(.title2.weight(.semibold))
            Text("Decant checks the app inside is signed and allowed, then installs it into your Applications folder.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button("Choose Disk Image…", action: choose)
                .keyboardShortcut("o")
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .background(RoundedRectangle(cornerRadius: 14).fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear))
        }
    }
}

private struct Working: View {
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// Name and version of the app, with a symbol for the outcome.
private struct Header: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CheckRow: View {
    let text: String
    var ok = true

    var body: some View {
        Label {
            Text(text).textSelection(.enabled)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(ok ? .green : .secondary)
        }
    }
}

private struct CheckedView: View {
    let model: InstallModel
    let url: URL
    let report: InstallReport
    let config: Configuration

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if report.canInstall {
                Header(symbol: "checkmark.seal.fill", tint: .green,
                       title: "\(appName) \(report.version ?? "")",
                       subtitle: report.bundleIdentifier)
                VStack(alignment: .leading, spacing: 8) {
                    CheckRow(text: "Signature is valid (Team ID \(report.teamID ?? "none"))")
                    if config.requireGatekeeperAssessment {
                        CheckRow(text: "Notarised and accepted by Gatekeeper")
                    } else {
                        CheckRow(text: "Gatekeeper check turned off by your organisation", ok: false)
                    }
                    if !config.allowedTeamIdentifiers.isEmpty {
                        CheckRow(text: "Developer is allowed by your organisation")
                    }
                    if report.action == .wouldUpdate {
                        CheckRow(text: "Updates \(report.previousVersion ?? "the installed copy") in \(destinationFolder)")
                    } else {
                        CheckRow(text: "Installs into \(destinationFolder)")
                    }
                }
                Spacer()
                HStack {
                    Button("Choose Another…") { model.chooseDiskImage() }
                    Spacer()
                    Button(report.action == .wouldUpdate ? "Update" : "Install") { model.install() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
            } else if report.action == .unchanged {
                Header(symbol: "checkmark.circle.fill", tint: .green,
                       title: "\(appName) \(report.version ?? "") is already installed",
                       subtitle: report.destination.map(abbreviate))
                Spacer()
                TrashOffer(model: model, url: url)
                FinishedButtons(model: model, report: report)
            } else {
                FailureView(model: model, report: report)
            }
        }
    }

    private var appName: String { (report.app as NSString?)?.deletingPathExtension ?? url.lastPathComponent }
    private var destinationFolder: String {
        report.destination.map { abbreviate(($0 as NSString).deletingLastPathComponent) } ?? "~/Applications"
    }
}

private struct FailureView: View {
    let model: InstallModel
    let report: InstallReport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Header(symbol: "xmark.octagon.fill", tint: .red,
                   title: ExitStatus(rawValue: report.exitCode)?.summary ?? "Something went wrong",
                   subtitle: report.app.map { "\($0) \(report.version ?? "")" })
            ScrollView {
                Text(report.message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            Text("Nothing was changed. Details are in ~/Library/Logs/decant.log.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                if report.exitCode == ExitStatus.appManagementDenied.rawValue {
                    // Turning Decant on there needs an administrator; then the user retries.
                    Button("Open App Management Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button("Choose Another…") { model.chooseDiskImage() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct FinishedView: View {
    let model: InstallModel
    let report: InstallReport

    var body: some View {
        if report.succeeded {
            VStack(alignment: .leading, spacing: 16) {
                Header(symbol: "checkmark.circle.fill", tint: .green,
                       title: report.action == .updated ? "Updated \(appName)" : "Installed \(appName)",
                       subtitle: report.message)
                Spacer()
                if let url = model.finishedDiskImage {
                    TrashOffer(model: model, url: url)
                }
                FinishedButtons(model: model, report: report)
            }
        } else {
            FailureView(model: model, report: report)
        }
    }

    private var appName: String { (report.app as NSString?)?.deletingPathExtension ?? "the app" }
}

/// Offers to move the disk image to the Trash once its app is installed.
private struct TrashOffer: View {
    @Bindable var model: InstallModel
    let url: URL

    var body: some View {
        HStack {
            switch model.trash {
            case .offered:
                Text("Move \(url.lastPathComponent) to the Trash?")
                Spacer()
                Button("Keep") { model.trash = .kept }
                Button("Move to Trash") { model.moveDiskImageToTrash() }
            case .trashed:
                Label("\(url.lastPathComponent) was moved to the Trash.", systemImage: "trash")
                Spacer()
            case .kept:
                Text("\(url.lastPathComponent) was kept.").foregroundStyle(.secondary)
                Spacer()
            case .failed(let reason):
                Label("Could not move it to the Trash: \(reason)", systemImage: "exclamationmark.triangle")
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }
}

private struct FinishedButtons: View {
    let model: InstallModel
    let report: InstallReport

    var body: some View {
        HStack {
            Button("Install Another…") { model.chooseDiskImage() }
            Spacer()
            if let destination = report.destination {
                let app = URL(fileURLWithPath: destination)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                Button("Open") {
                    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private func abbreviate(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}
