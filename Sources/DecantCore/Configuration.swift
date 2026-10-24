import Foundation

public enum RunningAppBehavior: String, Sendable, Codable, CaseIterable {
    /// Leave the running app alone and exit with `appRunning` so the MDM can retry later.
    case skip = "Skip"
    /// Replace the bundle on disk anyway. The running copy keeps going until it is relaunched.
    case replace = "Replace"
    /// Terminate the running app (SIGTERM, then SIGKILL) and replace it.
    case terminate = "Terminate"
}

/// Effective settings. Values come from managed preferences delivered by a configuration
/// profile (PayloadType `uk.street365.decant`), which users cannot change.
public struct Configuration: Sendable, Equatable, Codable {
    public static let domain = "uk.street365.decant"
    public static let managedPreferencesDirectory = "/Library/Managed Preferences"

    /// Require `spctl --assess --type execute` to accept the app (Developer ID + notarised).
    public var requireGatekeeperAssessment = true
    /// Accept ad-hoc signed apps (no Developer ID). Only for testing: such apps have no identity.
    public var allowAdHocSignatures = false
    /// If non-empty, only apps signed by one of these Team IDs are installed.
    public var allowedTeamIdentifiers: [String] = []
    /// Accept a software licence agreement embedded in the disk image on the user's behalf.
    public var acceptLicenseAgreements = false
    public var allowDowngrade = false
    public var runningAppBehavior: RunningAppBehavior = .skip
    public var logFilePath: String?
    /// Accept `install --user <name>`. Off by default, so installs only ever target the console
    /// user (or, with `--all-users`, every account). Only honoured from the device profile.
    public var allowUserOption = false
    /// Lets users install apps themselves, with `decant install` run without root or with
    /// Decant.app. When off, only root (the MDM) can install, and Decant.app refuses to open.
    public var allowUserInstalls = true
    /// Keeps the Decant app in the menu bar when its window is closed. nil leaves it to the user,
    /// who can turn it on in the app's settings; a value set by a profile overrides their choice.
    public var showInMenuBar: Bool?
    /// Opens the Decant app at login. nil leaves it to the user, as for `showInMenuBar`.
    public var openAtLogin: Bool?
    /// Installs new releases of decant from GitHub while the Mac is idle. nil leaves it to the
    /// logged-in user, who can turn it off in the app's settings (on by default).
    public var automaticUpdates: Bool?
    /// Days a release must have been published before it is installed automatically, 0 to
    /// `maxUpdateDeferralDays`. nil leaves it to the user (`defaultUpdateDeferralDays`).
    public var updateDeferralDays: Int?

    public static let defaultUpdateDeferralDays = 7
    public static let maxUpdateDeferralDays = 14

    /// Human-readable description of where values came from (for `show-config`).
    public var sources: [String] = ["defaults"]

    public init() {}

    /// `ShowInMenuBar` and `OpenAtLogin` as they apply to Decant.app: both are forced off while
    /// `AllowUserInstalls` is off, whatever the profile or the user chose.
    public var managedShowInMenuBar: Bool? { allowUserInstalls ? showInMenuBar : false }
    public var managedOpenAtLogin: Bool? { allowUserInstalls ? openAtLogin : false }

    public static let userInstallsDisabledMessage = "Installing apps with Decant has been disabled by your administrator"

    /// `LogFilePath`, else /Library/Logs/decant.log for root and ~/Library/Logs/decant.log otherwise.
    public func effectiveLogFilePath(isRoot: Bool = geteuid() == 0) -> String {
        if let logFilePath { return logFilePath }
        if isRoot { return "/Library/Logs/decant.log" }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/decant.log").path
    }

    enum Key {
        static let requireGatekeeperAssessment = "RequireGatekeeperAssessment"
        static let allowAdHocSignatures = "AllowAdHocSignatures"
        static let allowedTeamIdentifiers = "AllowedTeamIdentifiers"
        static let acceptLicenseAgreements = "AcceptLicenseAgreements"
        static let allowDowngrade = "AllowDowngrade"
        static let runningAppBehavior = "RunningAppBehavior"
        static let logFilePath = "LogFilePath"
        static let allowUserOption = "AllowUserOption"
        static let allowUserInstalls = "AllowUserInstalls"
        static let showInMenuBar = "ShowInMenuBar"
        static let openAtLogin = "OpenAtLogin"
        static let automaticUpdates = "AutomaticUpdates"
        static let updateDeferralDays = "UpdateDeferralDays"
    }

    public enum Scope: Sendable {
        case device, user
    }

    /// Applies keys from a preferences dictionary. Unknown keys are ignored; keys with the wrong
    /// type are reported in the returned warnings and ignored.
    @discardableResult
    public mutating func apply(_ dict: [String: Any], source: String, scope: Scope = .device) -> [String] {
        var warnings: [String] = []
        var dict = dict

        // `--user` loads that user's profile, so a user-scoped profile must not be able to grant it.
        if scope == .user, dict.removeValue(forKey: Key.allowUserOption) != nil {
            warnings.append("\(source): \(Key.allowUserOption) is only honoured in the device profile")
        }

        func bool(_ key: String, _ target: inout Bool) {
            guard let value = dict[key] else { return }
            if let b = value as? Bool { target = b } else { warnings.append("\(source): \(key) must be a boolean") }
        }
        func string(_ key: String) -> String? {
            guard let value = dict[key] else { return nil }
            if let s = value as? String, !s.isEmpty { return s }
            warnings.append("\(source): \(key) must be a non-empty string")
            return nil
        }

        bool(Key.requireGatekeeperAssessment, &requireGatekeeperAssessment)
        bool(Key.allowAdHocSignatures, &allowAdHocSignatures)
        bool(Key.acceptLicenseAgreements, &acceptLicenseAgreements)
        bool(Key.allowDowngrade, &allowDowngrade)
        bool(Key.allowUserOption, &allowUserOption)
        bool(Key.allowUserInstalls, &allowUserInstalls)
        func optionalBool(_ key: String, _ target: inout Bool?) {
            guard let value = dict[key] else { return }
            if let b = value as? Bool { target = b } else { warnings.append("\(source): \(key) must be a boolean") }
        }
        optionalBool(Key.showInMenuBar, &showInMenuBar)
        optionalBool(Key.openAtLogin, &openAtLogin)
        optionalBool(Key.automaticUpdates, &automaticUpdates)

        if let value = dict[Key.updateDeferralDays] {
            // Property lists store booleans as numbers too, so `true` must not read as 1 day.
            if let days = value as? Int, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() {
                if (0...Self.maxUpdateDeferralDays).contains(days) {
                    updateDeferralDays = days
                } else {
                    updateDeferralDays = min(max(days, 0), Self.maxUpdateDeferralDays)
                    warnings.append("\(source): \(Key.updateDeferralDays) must be 0 to \(Self.maxUpdateDeferralDays); using \(updateDeferralDays!)")
                }
            } else {
                warnings.append("\(source): \(Key.updateDeferralDays) must be an integer")
            }
        }

        if let path = string(Key.logFilePath) { logFilePath = path }

        if let raw = string(Key.runningAppBehavior) {
            if let behavior = RunningAppBehavior.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }) {
                runningAppBehavior = behavior
            } else {
                warnings.append("\(source): \(Key.runningAppBehavior) must be one of \(RunningAppBehavior.allCases.map(\.rawValue).joined(separator: ", "))")
            }
        }

        if let value = dict[Key.allowedTeamIdentifiers] {
            if let ids = value as? [String] {
                allowedTeamIdentifiers = ids.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else {
                warnings.append("\(source): \(Key.allowedTeamIdentifiers) must be an array of strings")
            }
        }

        if sources == ["defaults"] { sources = [] }
        sources.append(source)
        return warnings
    }
}

public struct ConfigurationLoader: Sendable {
    public var managedPreferencesDirectory: String
    /// Managed preference files are only trusted when owned by root and not writable by others.
    /// Tests turn this off.
    public var requireRootOwnership: Bool

    public init(
        managedPreferencesDirectory: String = Configuration.managedPreferencesDirectory,
        requireRootOwnership: Bool = true
    ) {
        self.managedPreferencesDirectory = managedPreferencesDirectory
        self.requireRootOwnership = requireRootOwnership
    }

    /// Precedence (lowest to highest): built-in defaults, user-scoped profile for `userName`,
    /// device-scoped profile, then `overrideFile` (only honoured for root; see the CLI).
    public func load(userName: String?, overrideFile: String? = nil) -> (Configuration, [String]) {
        var config = Configuration()
        var warnings: [String] = []

        var candidates: [(String, Configuration.Scope)] = []
        if let userName {
            candidates.append(("\(managedPreferencesDirectory)/\(userName)/\(Configuration.domain).plist", .user))
        }
        candidates.append(("\(managedPreferencesDirectory)/\(Configuration.domain).plist", .device))

        for (path, scope) in candidates {
            switch readTrusted(path) {
            case .missing: continue
            case .rejected(let why): warnings.append("Ignoring \(path): \(why)")
            case .loaded(let dict): warnings += config.apply(dict, source: path, scope: scope)
            }
        }

        if let overrideFile {
            switch Self.readPlist(overrideFile) {
            case .loaded(let dict): warnings += config.apply(dict, source: overrideFile)
            case .missing: warnings.append("Configuration file \(overrideFile) does not exist")
            case .rejected(let why): warnings.append("Ignoring \(overrideFile): \(why)")
            }
        }
        return (config, warnings)
    }

    enum ReadResult {
        case missing
        case rejected(String)
        case loaded([String: Any])
    }

    func readTrusted(_ path: String) -> ReadResult {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .missing }
        if requireRootOwnership {
            if (st.st_mode & S_IFMT) != S_IFREG { return .rejected("not a regular file") }
            if st.st_uid != 0 { return .rejected("not owned by root") }
            if st.st_mode & (S_IWGRP | S_IWOTH) != 0 { return .rejected("writable by group or others") }
        }
        return Self.readPlist(path)
    }

    static func readPlist(_ path: String) -> ReadResult {
        guard let data = FileManager.default.contents(atPath: path) else { return .missing }
        do {
            let object = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dict = object as? [String: Any] else { return .rejected("top level is not a dictionary") }
            return .loaded(dict)
        } catch {
            return .rejected("unreadable property list (\(error.localizedDescription))")
        }
    }
}
