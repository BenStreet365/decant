import Foundation

/// What an app bundle claims about itself, and separately whether its signature holds. Used for
/// the copy already installed in ~/Applications, which the user can change: when decant runs
/// as root it is produced by a helper process running as that user (see `Installer.inspectExisting`).
public struct BundleInspection: Codable, Sendable, Equatable {
    public var bundleIdentifier: String?
    public var shortVersion: String?
    public var buildVersion: String?
    /// nil when the signature is missing or not valid; `problem` says why.
    public var signing: SigningInfo?
    public var problem: String?

    public init(bundleIdentifier: String? = nil, shortVersion: String? = nil, buildVersion: String? = nil,
                signing: SigningInfo? = nil, problem: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.signing = signing
        self.problem = problem
    }

    public var displayVersion: String { AppBundle.displayVersion(short: shortVersion, build: buildVersion) }

    public static func inspect(_ url: URL) -> BundleInspection {
        var result = BundleInspection()
        do {
            let bundle = try AppBundle(url: url)
            result.bundleIdentifier = bundle.bundleIdentifier
            result.shortVersion = bundle.shortVersion
            result.buildVersion = bundle.buildVersion
            result.signing = try CodeSignature.inspect(url)
        } catch let error as DecantError {
            result.problem = error.message
        } catch {
            result.problem = error.localizedDescription
        }
        return result
    }
}

/// How far an existing install can be believed.
enum ExistingTrust: Equatable {
    /// Validly signed by the same team as the new copy: its version is real.
    case genuine
    /// Unsigned, tampered, ad-hoc or from another team, with the same name. Its version and
    /// bundle ID are whatever the user wrote, so they are not allowed to block the install.
    case untrusted(String)
    /// Something that is really a different app, which is never overwritten.
    case conflict(String)

    static func assess(_ existing: BundleInspection, sourceBundleID: String, sourceSigning: SigningInfo) -> ExistingTrust {
        guard let bundleID = existing.bundleIdentifier else {
            return .conflict("exists but is not a valid app bundle (\(existing.problem ?? "unknown problem"))")
        }
        let signing = existing.signing
        if let team = sourceSigning.teamID, let signing, !signing.isAdHoc, signing.teamID == team {
            guard bundleID == sourceBundleID else {
                return .conflict("is a different app from the same developer (installed \(bundleID), image \(sourceBundleID))")
            }
            return .genuine
        }
        // A user cannot forge another developer's signature, so a validly signed app with its own
        // Team ID and a different bundle ID really is something else.
        if let signing, !signing.isAdHoc, let team = signing.teamID, bundleID != sourceBundleID {
            return .conflict("is a different app (installed \(bundleID) from team \(team), image \(sourceBundleID))")
        }
        let reason: String
        if let signing {
            reason = signing.isAdHoc ? "it is ad-hoc signed"
                : "it is signed by team \(signing.teamID ?? "none"), not \(sourceSigning.teamID ?? "none")"
        } else {
            reason = "its signature is not valid: \(existing.problem ?? "unknown problem")"
        }
        return .untrusted(reason)
    }
}
