import DecantCore
import Foundation
import Observation
import ServiceManagement
import os

/// The app's settings. The user's choices are kept in the app's own defaults; `ShowInMenuBar`,
/// `OpenAtLogin`, `AutomaticUpdates` and `UpdateDeferralDays` in a managed profile override them.
/// The update daemon reads the logged-in user's update choices from the same defaults.
/// `AllowUserInstalls` set to false overrides the menu bar and login item settings, turning both off.
@MainActor @Observable
final class AppPreferences {
    enum Key: String {
        case showInMenuBar = "ShowInMenuBar"
        case openAtLogin = "OpenAtLogin"
    }

    private(set) var menuBar: ManagedSetting
    private(set) var openAtLogin: ManagedSetting
    /// False when the profile turns off `AllowUserInstalls`, which disables the whole app.
    private(set) var userInstallsAllowed: Bool
    private(set) var updates: UpdatePolicy
    /// What the update daemon last found, if it has run.
    private(set) var updateState: UpdateState?
    /// Called when the effective menu bar value changes.
    @ObservationIgnored var onMenuBarChange: ((Bool) -> Void)?
    /// Called when a profile turns off `AllowUserInstalls` while the app is running.
    @ObservationIgnored var onDisabled: (() -> Void)?

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: Configuration.domain, category: "app")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let managed = Self.managedConfiguration()
        menuBar = ManagedSetting(managed: managed.managedShowInMenuBar, userChoice: defaults.bool(forKey: Key.showInMenuBar.rawValue))
        openAtLogin = ManagedSetting(managed: managed.managedOpenAtLogin, userChoice: defaults.bool(forKey: Key.openAtLogin.rawValue))
        userInstallsAllowed = managed.allowUserInstalls
        updates = Self.updatePolicy(managed, defaults)
        updateState = UpdateState.load()
    }

    /// The user's toggles. Ignored while the setting is managed.
    func setMenuBar(_ enabled: Bool) {
        guard !menuBar.isManaged else { return }
        defaults.set(enabled, forKey: Key.showInMenuBar.rawValue)
        refresh()
    }

    func setOpenAtLogin(_ enabled: Bool) {
        guard !openAtLogin.isManaged else { return }
        defaults.set(enabled, forKey: Key.openAtLogin.rawValue)
        refresh()
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        guard !updates.automatic.isManaged else { return }
        defaults.set(enabled, forKey: UpdatePolicy.automaticUpdatesKey)
        refresh()
    }

    func setUpdateDeferralDays(_ days: Int) {
        guard !updates.deferralDays.isManaged else { return }
        defaults.set(min(max(days, 0), Configuration.maxUpdateDeferralDays), forKey: UpdatePolicy.deferralDaysKey)
        refresh()
    }

    private static func updatePolicy(_ managed: Configuration, _ defaults: UserDefaults) -> UpdatePolicy {
        UpdatePolicy(config: managed,
                     userEnabled: defaults.object(forKey: UpdatePolicy.automaticUpdatesKey) as? Bool,
                     userDeferralDays: defaults.object(forKey: UpdatePolicy.deferralDaysKey) as? Int)
    }

    /// Re-reads the managed profile, which can arrive or change while the app runs, and applies
    /// any change.
    func refresh() {
        let managed = Self.managedConfiguration()
        let newMenuBar = ManagedSetting(managed: managed.managedShowInMenuBar, userChoice: defaults.bool(forKey: Key.showInMenuBar.rawValue))
        let menuBarChanged = newMenuBar.isEnabled != menuBar.isEnabled
        let disabled = userInstallsAllowed && !managed.allowUserInstalls
        menuBar = newMenuBar
        openAtLogin = ManagedSetting(managed: managed.managedOpenAtLogin, userChoice: defaults.bool(forKey: Key.openAtLogin.rawValue))
        userInstallsAllowed = managed.allowUserInstalls
        updates = Self.updatePolicy(managed, defaults)
        updateState = UpdateState.load()
        syncLoginItem()
        if menuBarChanged { onMenuBarChange?(newMenuBar.isEnabled) }
        if disabled { onDisabled?() }
    }

    private static func managedConfiguration() -> Configuration {
        let user = TargetUser.lookup(uid: getuid())?.name
        return ConfigurationLoader().load(userName: user).0
    }

    /// Registers or removes Decant's login item to match `openAtLogin`.
    func syncLoginItem() {
        let service = SMAppService.mainApp
        do {
            if openAtLogin.isEnabled, service.status != .enabled {
                try service.register()
            } else if !openAtLogin.isEnabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            logger.error("Cannot update the login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
