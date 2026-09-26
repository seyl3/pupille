import Foundation

/// Everything PupilleKit needs from the host app. Nothing is hardcoded in the SDK.
public struct PupilleConfiguration {
    /// The backend running the Pupille routes for this app.
    public var backendURL: URL
    /// World Developer Portal app ID, for example `app_…`.
    public var worldAppID: String
    /// World relying-party ID, for example `rp_…`. The backend holds the matching signing key.
    public var worldRPID: String
    /// The World action the backend signs requests for.
    public var worldAction: String
    /// Shown in World App when the user approves the proof.
    public var worldActionDescription: String
    /// The backend's Ed25519 issuer public key (32 raw bytes). Certificates must verify under it.
    public var issuerPublicKey: Data
    /// App Attest app IDs (`TEAMID.bundle.id`) whose captures you accept. `nil` accepts any app the issuer certified.
    public var trustedAppIDs: Set<String>?
    /// Where the SDK keeps this device's key references and enrollment state.
    public var defaults: UserDefaults

    public init(
        backendURL: URL,
        worldAppID: String,
        worldRPID: String,
        worldAction: String = "pupille-profile-v1",
        worldActionDescription: String = "Verify one human per profile",
        issuerPublicKey: Data,
        trustedAppIDs: Set<String>? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.backendURL = backendURL
        self.worldAppID = worldAppID
        self.worldRPID = worldRPID
        self.worldAction = worldAction
        self.worldActionDescription = worldActionDescription
        self.issuerPublicKey = issuerPublicKey
        self.trustedAppIDs = trustedAppIDs
        self.defaults = defaults
    }
}

/// The World ID environment a proof was made in.
public enum WorldEnvironment: String, Sendable, Codable {
    case staging, production
}
