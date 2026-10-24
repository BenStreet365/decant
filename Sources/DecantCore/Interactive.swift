import Foundation

/// Support for the Decant app, which installs as the logged-in user with the same checks and
/// configuration as `decant install` run without root.
public enum InteractiveInstall {
    /// Checks (`dryRun`) or installs the disk image for the current user. The configuration is
    /// reloaded every time, so a profile that arrives while the app is open applies straight away,
    /// and is returned with the report so the app can say which checks ran. With `matching`, the
    /// dry run the user saw, only the very app it found is installed, in case the disk image was
    /// changed since.
    public static func run(diskImage: URL, dryRun: Bool, matching check: InstallReport? = nil,
                           loader: ConfigurationLoader = ConfigurationLoader()) -> (InstallReport, Configuration) {
        let userName = TargetUser.lookup(uid: getuid())?.name
        let log = Log()
        log.quiet = true
        let (config, warnings) = loader.load(userName: userName)
        log.attachFile(at: config.effectiveLogFilePath())
        warnings.forEach { log.warning($0) }

        var request = InstallRequest(diskImagePath: diskImage.path, dryRun: dryRun)
        if let check {
            request.expectedBundleID = check.bundleIdentifier
            // Without a cdhash nothing ties the install to the check, so refuse rather than guess.
            request.expectedCDHash = check.cdHash ?? ""
        }
        request.configuredFor = userName
        request.checksConfiguredUser = true
        return (Installer(config: config, log: log).install(request), config)
    }
}

/// An app setting the user can change unless a profile sets it (`ShowInMenuBar`, `OpenAtLogin`),
/// in which case the profile's value wins and the setting is locked.
public struct ManagedSetting: Equatable, Sendable {
    public var isEnabled: Bool
    public var isManaged: Bool

    public init(managed: Bool?, userChoice: Bool) {
        isEnabled = managed ?? userChoice
        isManaged = managed != nil
    }
}

/// A value the user can change unless a profile sets it (`UpdateDeferralDays`).
public struct ManagedValue<Value: Equatable & Sendable>: Equatable, Sendable {
    public var value: Value
    public var isManaged: Bool

    public init(managed: Value?, userChoice: Value) {
        value = managed ?? userChoice
        isManaged = managed != nil
    }
}

extension InstallReport {
    /// A dry run found the app can be installed or updated.
    public var canInstall: Bool { action == .wouldInstall || action == .wouldUpdate }
    public var succeeded: Bool { exitCode == ExitStatus.success.rawValue }
}

extension ExitStatus {
    /// A headline for people, shown above the detailed message.
    public var summary: String {
        switch self {
        case .success: "Done"
        case .failure: "Something went wrong"
        case .usage: "Something went wrong"
        case .notAuthorized: "Not allowed"
        case .noTargetUser: "Cannot tell who to install for"
        case .diskImageError: "The disk image could not be opened"
        case .unsupportedLayout: "This disk image cannot be installed by Decant"
        case .invalidSignature: "The app is not properly signed"
        case .gatekeeperRejected: "The app is not notarised by Apple"
        case .teamNotAllowed: "This developer is not allowed by your organisation"
        case .bundleIDMismatch: "This is not the expected app"
        case .appRunning: "The app is running. Quit it and try again"
        case .downgradeRefused: "A newer version is already installed"
        case .destinationConflict: "Something else is in the way in your Applications folder"
        case .busy: "Another install is in progress. Try again shortly"
        case .appManagementDenied: "Decant needs permission to update apps"
        case .installFailed: "The install failed"
        case .uninstallIncomplete: "Decant could not be fully removed"
        case .updateFailed: "Decant could not be updated"
        }
    }
}
