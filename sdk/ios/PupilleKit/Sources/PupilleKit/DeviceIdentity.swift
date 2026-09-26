import CryptoKit
import DeviceCheck
import Foundation
import LocalAuthentication
import Security

/// This device's keys and enrollment state, kept in the host app's `UserDefaults`.
/// The key names match the Pupille app, so the SDK reads a profile it created.
@MainActor
struct DeviceIdentity {
    let defaults: UserDefaults

    private enum Key {
        static let handle = "profileHandle"
        static let profileID = "profileID"
        static let profileKey = "profileKeyReference"
        static let attestKeyID = "registeredAttestKeyID"
        static let attestServerKeyID = "registeredAttestServerKeyID"
        static let all = [handle, profileID, profileKey, attestKeyID, attestServerKeyID]
    }

    var handle: String? {
        get { defaults.string(forKey: Key.handle).flatMap { $0.isEmpty ? nil : $0 } }
        nonmutating set { defaults.set(newValue, forKey: Key.handle) }
    }

    var storedProfileID: Data? {
        guard let hex = defaults.string(forKey: Key.profileID), let id = Data(hex: hex), id.count == 16 else { return nil }
        return id
    }

    var storedAttestKeyID: String? { defaults.string(forKey: Key.attestKeyID) }

    func forget() {
        for key in Key.all { defaults.removeObject(forKey: key) }
    }

    func profileID() throws -> Data {
        if let id = storedProfileID { return id }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PupilleError.randomFailure
        }
        let id = Data(bytes)
        defaults.set(id.hex, forKey: Key.profileID)
        return id
    }

    /// Secure Enclave P-256 key: non-exportable, Face ID for every signature.
    func profileKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let data = defaults.data(forKey: Key.profileKey) {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
        }
        guard let access = SecAccessControlCreateWithFlags(nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil) else {
            throw PupilleError.secureEnclaveKeyUnavailable
        }
        let context = LAContext()
        context.localizedReason = "Create your verified capture key"
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
        defaults.set(key.dataRepresentation, forKey: Key.profileKey)
        return key
    }

    /// The App Attest key registered with the backend, attesting a new one if needed.
    func registeredAttestKey(api: APIClient) async throws -> (appleID: String, serverID: String) {
        struct Challenge: Decodable { let challengeId: String; let challenge: String }
        struct Status: Decodable { let registered: Bool }
        struct Registered: Decodable { let keyId: String }

        if let appleID = defaults.string(forKey: Key.attestKeyID) {
            let serverID = defaults.string(forKey: Key.attestServerKeyID)
                ?? appleID.replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            let status: Status = try await api.post("/v1/attest/status", ["keyId": serverID])
            if status.registered {
                defaults.set(serverID, forKey: Key.attestServerKeyID)
                return (appleID, serverID)
            }
            defaults.removeObject(forKey: Key.attestKeyID)
            defaults.removeObject(forKey: Key.attestServerKeyID)
        }
        guard DCAppAttestService.shared.isSupported else { throw PupilleError.appAttestUnsupported }
        let challenge: Challenge = try await api.post("/v1/attest/challenge", [:])
        guard let bytes = Data(hex: challenge.challenge) else { throw PupilleError.invalidResponse }
        let keyID = try await DCAppAttestService.shared.generateKey()
        let attestation = try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: bytes)))
        let registered: Registered = try await api.post("/v1/attest/register", [
            "challengeId": challenge.challengeId, "keyId": keyID,
            "attestationObject": attestation.base64EncodedString()
        ])
        defaults.set(keyID, forKey: Key.attestKeyID)
        defaults.set(registered.keyId, forKey: Key.attestServerKeyID)
        return (keyID, registered.keyId)
    }
}
