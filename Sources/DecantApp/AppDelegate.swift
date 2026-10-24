import AppKit
import DecantCore
import ServiceManagement
import SwiftUI

@main
@MainActor
enum DecantApp {
    /// Hidden argument `decant uninstall` uses, running as each logged-in user, to remove the
    /// login item before the app is deleted.
    static let unregisterLoginItemArgument = "--unregister-login-item"
    /// Passed when Decant relaunches itself after an update, so it comes back without its window.
    static let relaunchedArgument = "--relaunched-after-update"

    static func main() {
        if CommandLine.arguments.contains(unregisterLoginItemArgument) {
            let service = SMAppService.mainApp
            if service.status == .enabled || service.status == .requiresApproval {
                do {
                    try service.unregister()
                } catch {
                    FileHandle.standardError.write(Data("Cannot remove the login item: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let website = URL(string: "https://decant.street365.uk")!

    let model = InstallModel()
    let preferences = AppPreferences()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var updateTimer: Timer?
    private var bundleWatcher: DispatchSourceFileSystemObject?
    private var pendingRelaunchCheck: DispatchWorkItem?
    /// Check for Updates is running or showing its result, so Decant must not relaunch under it.
    private var checkingForUpdates = false
    private var updateProgressWindow: NSWindow?

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.onMenuBarChange = { [weak self] _ in self?.applyMenuBarSetting() }
        preferences.onDisabled = { [weak self] in self?.quitDisabled(quietly: false) }
        // Removes the login item, which is forced off while the app is disabled.
        preferences.syncLoginItem()
        if !preferences.userInstallsAllowed {
            // Nobody asked for the app at login, so it leaves without a word.
            quitDisabled(quietly: Self.launchedAsLoginItem || CommandLine.arguments.contains(DecantApp.relaunchedArgument))
            return
        }
        applyMenuBarSetting()
        // At login Decant only appears in the menu bar if it lives there; otherwise it opens its window.
        let quietLaunch = Self.launchedAsLoginItem || CommandLine.arguments.contains(DecantApp.relaunchedArgument)
        if !(preferences.menuBar.isEnabled && quietLaunch) {
            showMainWindow()
        }
        watchBundle()
        // In case the watcher misses an update, for example one that replaced the whole bundle
        // while it was being re-armed, and to notice a profile that disables the app while it
        // sits in the menu bar.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let delegate = NSApp.delegate as? AppDelegate else { return }
                delegate.preferences.refresh()
                delegate.relaunchIfUpdated()
            }
        }
    }

    /// `AllowUserInstalls` is off: tells the user (unless `quietly`) and quits. An install that
    /// started before the profile arrived may finish (quitting asks first); any later one is
    /// refused by the installer, which reloads the configuration each time.
    private func quitDisabled(quietly: Bool) {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        if !quietly {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Decant has been disabled by your administrator"
            alert.informativeText = "Contact your IT department if you need an app installed."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
        }
        NSApp.terminate(nil)
    }

    /// Watches the bundle's Info.plist, which the update daemon's package replaces, so Decant can
    /// relaunch into the new version straight away.
    private func watchBundle() {
        bundleWatcher?.cancel()
        bundleWatcher = nil
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist").path
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib],
                                                               queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.bundleChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        bundleWatcher = source
    }

    /// Waits until the bundle has been quiet for a few seconds, so the installer has finished
    /// writing it, then relaunches if the version changed and watches the new Info.plist.
    private func bundleChanged() {
        pendingRelaunchCheck?.cancel()
        let check = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let delegate = NSApp.delegate as? AppDelegate else { return }
                delegate.watchBundle()
                delegate.relaunchIfUpdated()
            }
        }
        pendingRelaunchCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: check)
    }

    /// The update daemon replaces Decant.app while it may be running in the menu bar. Once that
    /// copy is idle (no window open, nothing in progress), it relaunches into the new version.
    func relaunchIfUpdated() {
        let running = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let infoPlist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let installed = info["CFBundleVersion"] as? String, installed != running,
              !model.isBusy, !checkingForUpdates, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        relaunch()
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = [DecantApp.relaunchedArgument]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        preferences.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !preferences.menuBar.isEnabled
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// Disk images opened from Finder ("Open With" or dropped on the Dock icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        showMainWindow()
        if let url = urls.first { model.open(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Decant is still working"
        alert.informativeText = "Quitting now could leave the install unfinished."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // MARK: Windows

    @objc func showMainWindow() {
        guard preferences.userInstallsAllowed else { return quitDisabled(quietly: false) }
        if mainWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ContentView(model: model)))
            window.title = "Decant"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("Main")
            mainWindow = window
        }
        present(mainWindow!)
    }

    @objc func showSettings() {
        guard preferences.userInstallsAllowed else { return quitDisabled(quietly: false) }
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(preferences: preferences)))
            window.title = "Decant Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        preferences.refresh()
        present(settingsWindow!)
    }

    @objc func chooseDiskImage() {
        showMainWindow()
        model.chooseDiskImage()
    }

    @objc func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Installs apps from disk images into your Applications folder.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(string: "decant.street365.uk", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .link: Self.website,
        ]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: Updates

    /// Looks for a newer release, bypassing the deferral unless a profile sets one, and offers to
    /// install it now. The update service installs it as root.
    @objc func checkForUpdates() {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        let version = Self.version
        Task.detached {
            let config = ConfigurationLoader().load(userName: TargetUser.lookup(uid: getuid())?.name).0
            let report = Updater(config: config, log: Log(), currentVersion: version).run(checkOnly: true, mode: .requested)
            await MainActor.run { self.showUpdateCheck(report) }
        }
    }

    private func showUpdateCheck(_ report: UpdateReport) {
        let alert = NSAlert()
        switch report.action {
        case .available:
            alert.messageText = "Decant \(report.availableVersion ?? "") is available"
            alert.informativeText = "You have version \(report.currentVersion). Install the new version now?"
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Not Now")
        case .upToDate:
            alert.messageText = "Decant is up to date"
            alert.informativeText = "Version \(report.currentVersion) is the newest version."
        case .failed:
            alert.alertStyle = .warning
            alert.messageText = "Cannot check for updates"
            alert.informativeText = report.message
        default:
            alert.messageText = report.availableVersion.map { "Decant \($0) is available" } ?? "Updates are managed by your organisation"
            alert.informativeText = report.action == .disabled ? "Your organisation installs new versions of Decant for you." : report.message
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, report.action == .available else { return finishUpdateCheck() }
        installUpdate(report.availableVersion ?? "")
    }

    private func installUpdate(_ version: String) {
        let window = NSWindow(contentViewController: NSHostingController(rootView:
            ProgressView("Installing Decant \(version)…").padding(24).frame(minWidth: 280)))
        window.title = "Decant Update"
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.center()
        updateProgressWindow = window
        present(window)
        Task.detached {
            let report: UpdateReport
            do {
                report = try UpdateService.requestUpdate()
            } catch {
                var failed = UpdateReport(action: .failed, message: (error as? DecantError)?.message ?? error.localizedDescription,
                                          currentVersion: Self.version)
                failed.exitCode = ExitStatus.updateFailed.rawValue
                report = failed
            }
            await MainActor.run { self.showUpdateResult(report) }
        }
    }

    private func showUpdateResult(_ report: UpdateReport) {
        updateProgressWindow?.close()
        updateProgressWindow = nil
        preferences.refresh()
        let alert = NSAlert()
        if report.action == .updated {
            alert.messageText = "Decant has been updated to \(report.availableVersion ?? "the newest version")"
            alert.informativeText = model.isBusy ? "Decant will reopen once it has finished what it is doing."
                                                 : "Decant needs to reopen to use the new version."
            alert.addButton(withTitle: model.isBusy ? "OK" : "Reopen Decant")
        } else {
            alert.alertStyle = report.action == .failed ? .warning : .informational
            alert.messageText = report.action == .failed ? "Decant could not be updated" : "Decant was not updated"
            alert.informativeText = report.message
        }
        NSApp.activate()
        alert.runModal()
        if report.action == .updated, !model.isBusy { return relaunch() }
        finishUpdateCheck()
    }

    private func finishUpdateCheck() {
        checkingForUpdates = false
        relaunchIfUpdated()
    }

    nonisolated static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    @objc func openWebsite() {
        NSWorkspace.shared.open(Self.website)
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Reopening starts afresh, unless a check or install is still running.
        if notification.object as? NSWindow === mainWindow {
            model.reset()
        }
        // In the menu bar, Decant leaves the Dock once its windows are closed.
        guard preferences.menuBar.isEnabled else { return }
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                NSApp.setActivationPolicy(.accessory)
                self.relaunchIfUpdated()
            }
        }
    }

    // MARK: Menu bar

    private func applyMenuBarSetting() {
        if preferences.menuBar.isEnabled {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = Self.statusImage()
                item.button?.setAccessibilityLabel("Decant")
                item.menu = makeStatusMenu()
                statusItem = item
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            NSApp.setActivationPolicy(.regular)
        }
    }

    private static func statusImage() -> NSImage? {
        if let image = Bundle.main.image(forResource: "decantTemplate") {
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "externaldrive.badge.plus", accessibilityDescription: "Decant")
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open Decant", #selector(showMainWindow)))
        menu.addItem(item("Install Disk Image…", #selector(chooseDiskImage)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(item("About Decant", #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Decant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: Main menu

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Decant")
        app.addItem(item("About Decant", #selector(showAbout)))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(showSettings), ","))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Decant", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Decant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = NSMenu(title: "File")
        file.addItem(item("Open Disk Image…", #selector(chooseDiskImage), "o"))
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(item("Decant", #selector(showMainWindow), "0"))
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        help.addItem(.separator())
        help.addItem(item("Decant Website", #selector(openWebsite)))
        NSApp.helpMenu = help

        for menu in [app, file, edit, window, help] {
            let top = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            top.submenu = menu
            main.addItem(top)
        }
        return main
    }
}
