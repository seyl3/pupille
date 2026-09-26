import Crypto
import Foundation

/// Software P-256 signing, API-compatible with what a real
/// `SecureEnclave.P256.Signing.PrivateKey` would provide (raw 64-byte r‖s signatures,
/// 65-byte X9.63 public key). THIS IS NOT SECURE-ENCLAVE-BACKED — it exists so
/// PupilleCore's protocol logic and tests can run on Linux, where there is no Secure
/// Enclave. The real iOS app must use `SecureEnclave.P256.Signing.PrivateKey` with
/// `SecAccessControl(.privateKeyUsage, .biometryCurrentSet)`; that substitution is
/// tracked in docs/WORKLOG.md under HANDOFF.
public struct SoftwareProfileKey {
    private let key: P256.Signing.PrivateKey

    public init() { key = P256.Signing.PrivateKey() }

    /// 65-byte X9.63 uncompressed public key (0x04 || X || Y), matching CryptoKit's `x963Representation`.
    public var publicKeyX963: [UInt8] { Array(key.publicKey.x963Representation) }

    /// Raw r‖s (64 bytes), matching `P256.Signing.ECDSASignature.rawRepresentation`.
    public func sign(_ message: [UInt8]) throws -> [UInt8] {
        try Array(key.signature(for: Data(message)).rawRepresentation)
    }
}

public enum ProfileKeyVerifier {
    public static func verify(signature: [UInt8], message: [UInt8], publicKeyX963: [UInt8]) -> Bool {
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: Data(publicKeyX963)),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: Data(signature))
        else { return false }
        return publicKey.isValidSignature(sig, for: Data(message))
    }
}
