import Foundation
import Security

/// How a signature is anchored, as reported by `check-app`.
public enum SigningState: String, Sendable, Codable, CaseIterable {
    case testFlight = "TestFlight"
    case developerID = "DeveloperID"
    case enterprise = "Enterprise"
    case appStore = "AppStore"
    case apple = "Apple"
}

public struct SigningInfo: Sendable, Codable, Equatable {
    /// The Team ID, only when Apple vouches for it: it is in an Apple-issued leaf certificate, or
    /// Apple signed the code itself (Mac App Store, Apple's own software). Every check of who
    /// made the app uses this.
    public var teamID: String?
    /// A Team ID the signature claims but no Apple certificate backs, for example from a
    /// self-signed certificate. Shown, never trusted.
    public var unverifiedTeamID: String?
    public var signingID: String?
    /// Hex code directory hash of the main executable (40 characters for SHA-1/truncated SHA-256).
    public var cdHash: String?
    public var isAdHoc: Bool
    /// Signing states this code satisfies.
    public var states: Set<SigningState>

    public init(teamID: String?, signingID: String?, cdHash: String?, isAdHoc: Bool, states: Set<SigningState>,
                unverifiedTeamID: String? = nil) {
        self.teamID = teamID
        self.unverifiedTeamID = unverifiedTeamID
        self.signingID = signingID
        self.cdHash = cdHash
        self.isAdHoc = isAdHoc
        self.states = states
    }
}

public enum CodeSignature {
    /// Validates the code signature of a bundle (all architectures, nested code, strict) and
    /// returns its identity. Throws `invalidSignature` for unsigned or tampered code.
    public static func inspect(_ url: URL) throws -> SigningInfo {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess, let code = staticCode else {
            throw DecantError(.invalidSignature, "Cannot read code signature of \(url.path) (OSStatus \(status))")
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var cfError: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &cfError)
        guard status == errSecSuccess else {
            _ = cfError?.takeRetainedValue()
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            let reason = "\(text) (OSStatus \(status))"
            throw DecantError(.invalidSignature, "Code signature of \(url.lastPathComponent) is not valid: \(reason)")
        }

        var infoRef: CFDictionary?
        status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        guard status == errSecSuccess, let info = infoRef as? [String: Any] else {
            throw DecantError(.invalidSignature, "Cannot read signing information for \(url.path) (OSStatus \(status))")
        }

        let claimedTeamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let signingID = info[kSecCodeInfoIdentifier as String] as? String
        let cdHash = (info[kSecCodeInfoUnique as String] as? Data).map { $0.map { String(format: "%02x", $0) }.joined() }
        let codeFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdHoc = codeFlags & 0x2 != 0 // kSecCodeSignatureAdhoc

        var states = Set<SigningState>()
        for (state, requirement) in stateRequirements where satisfies(code, requirement) {
            states.insert(state)
        }

        // The Team ID field is whatever the signer wrote. Validity alone, with no requirement,
        // also accepts a self-signed certificate, so only believe it if Apple backs it.
        let leafMatches = claimedTeamID.flatMap(teamRequirement).map { satisfies(code, $0) } ?? false
        let teamID = verifiedTeamID(claimed: claimedTeamID, isAdHoc: isAdHoc, leafCertificateMatches: leafMatches, states: states)
        return SigningInfo(teamID: teamID, signingID: signingID, cdHash: cdHash, isAdHoc: isAdHoc, states: states,
                           unverifiedTeamID: teamID == nil ? claimedTeamID : nil)
    }

    /// An Apple-issued leaf certificate whose organisational unit is `team`. Apple's Team IDs are
    /// letters and digits; anything else cannot be one, and is not put into the requirement.
    static func teamRequirement(_ team: String) -> String? {
        guard !team.isEmpty, team.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) }) else {
            return nil
        }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The claimed Team ID if Apple vouches for it, else nil. Mac App Store and Apple's own code
    /// are signed by Apple, whose leaf certificate is not the developer's, but then Apple signed
    /// the Team ID too.
    static func verifiedTeamID(claimed: String?, isAdHoc: Bool, leafCertificateMatches: Bool, states: Set<SigningState>) -> String? {
        guard let claimed, !claimed.isEmpty, !isAdHoc else { return nil }
        if leafCertificateMatches || states.contains(.appStore) || states.contains(.apple) { return claimed }
        return nil
    }

    /// Requirements used to classify a signature into signing states.
    static let stateRequirements: [(SigningState, String)] = [
        (.apple, "anchor apple"),
        (.appStore, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"),
        (.developerID, "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"),
        (.testFlight, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.25.1] exists"),
    ]

    static func satisfies(_ code: SecStaticCode, _ requirementText: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
