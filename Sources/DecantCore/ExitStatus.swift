import Foundation

/// Process exit codes. These are stable so that MDM scripts and reporting can act on them.
public enum ExitStatus: Int32, Sendable, Codable {
    case success = 0
    case failure = 1
    case usage = 64

    /// A non-root user tried a root-only option (--user for someone else, --config).
    case notAuthorized = 10
    /// Running as root but nobody is logged in at the console and no user was specified.
    case noTargetUser = 11

    case diskImageError = 20
    /// The disk image is not a simple drag-and-drop install. Nothing was changed.
    case unsupportedLayout = 21
    case invalidSignature = 22
    case gatekeeperRejected = 23
    /// Team ID not in AllowedTeamIdentifiers or not the one given with --expect-team-id.
    case teamNotAllowed = 24
    /// The app's bundle ID is not the one given with --expect-bundle-id.
    case bundleIDMismatch = 25

    // 30 and 31 were DDM App Settings results and are retired. Do not reuse them.

    /// The app is running and configuration says to try again later.
    case appRunning = 40
    case downgradeRefused = 41
    /// Something unrelated (or unsafe) occupies the destination path.
    case destinationConflict = 42
    /// Another decant install held the lock for too long. Retry later.
    case busy = 43
    /// macOS App Management blocked replacing the installed app. The process that started decant
    /// (Decant.app, Terminal, or the MDM agent) needs App Management in Privacy & Security.
    case appManagementDenied = 44

    case installFailed = 50
    /// `uninstall` could not remove everything; the report lists what is left.
    case uninstallIncomplete = 51
    /// `update` could not check for, download or install a new release of decant.
    case updateFailed = 52
}

public struct DecantError: Error, CustomStringConvertible, Sendable {
    public let status: ExitStatus
    public let message: String

    public init(_ status: ExitStatus, _ message: String) {
        self.status = status
        self.message = message
    }

    public var description: String { message }
}
