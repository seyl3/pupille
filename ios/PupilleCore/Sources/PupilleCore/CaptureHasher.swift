import Crypto
import Foundation

/// Byte-exact protocol derivations from docs/ARCHITECTURE.md §06.
/// Swift and TypeScript (backend/src/proto) must produce identical output;
/// both are checked against the shared fixture in Tests/PupilleCoreTests/Fixtures.
public enum CaptureHasher {
    private static func tag(_ s: String) -> [UInt8] { Array(s.utf8) }

    public static func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(data)))
    }

    // MARK: - Profile creation / key rotation

    public static func profileCommitment(profileId: [UInt8], profilePublicKey: [UInt8], handle: String) -> [UInt8] {
        sha256(tag("pupille:profile:v1") + profileId + profilePublicKey + Array(handle.utf8))
    }

    public static func profileSignal(profileCommitment: [UInt8]) -> String {
        "0x" + hex(profileCommitment)
    }

    /// Message to sign for `profilePoP` (proof of key possession). Caller signs this with the profile key.
    public static func profilePoPMessage(profileCommitment: [UInt8]) -> [UInt8] {
        tag("pupille:profile-sig:v1") + profileCommitment
    }

    // MARK: - Per capture

    public static func imageHash(imageBytes: [UInt8]) -> [UInt8] { sha256(imageBytes) }

    /// 32 zero bytes when depth is absent, per §06.
    public static func depthHash(depthBytes: [UInt8]?) -> [UInt8] {
        guard let depthBytes else { return [UInt8](repeating: 0, count: 32) }
        return sha256(depthBytes)
    }

    public static func clientDataHash(imageHash: [UInt8], depthHash: [UInt8], challenge: [UInt8]) -> [UInt8] {
        sha256(tag("pupille:assert:v1") + imageHash + depthHash + challenge)
    }

    public static func assertionHash(assertion: [UInt8]) -> [UInt8] { sha256(assertion) }

    public static func captureCommitment(
        imageHash: [UInt8],
        depthHash: [UInt8],
        challenge: [UInt8],
        assertionHash: [UInt8],
        profileId: [UInt8],
        profilePublicKey: [UInt8]
    ) -> [UInt8] {
        sha256(
            tag("pupille:capture:v1") + imageHash + depthHash + challenge
                + assertionHash + profileId + profilePublicKey
        )
    }

    /// Message to sign for `postSignature`. Caller signs this with the profile key.
    public static func postSignatureMessage(captureCommitment: [UInt8]) -> [UInt8] {
        tag("pupille:post-sig:v1") + captureCommitment
    }

    public static func worldSignal(captureCommitment: [UInt8]) -> String {
        "0x" + hex(captureCommitment)
    }

    // MARK: - World signal hash

    /// `signal_hash = "0x" + hex(uint256(keccak256(signalBytes)) >> 8)`, i.e. IDKit's `hashSignal`.
    /// A `0x`+even-hex signal is decoded to raw bytes before hashing; anything else is hashed as UTF-8.
    /// Ported from the documented algorithm (see Keccak256.swift) since idkit-swift's hashSignal is only
    /// available via a precompiled Apple-platform XCFramework — verified byte-exact against
    /// `@worldcoin/idkit-core/hashing`'s hashSignal in the shared fixture tests.
    public static func hashSignal(_ signal: String) -> String {
        let bytes = signalBytes(signal)
        let digest = Keccak256.hash(bytes)
        // uint256(digest) >> 8 == drop the first byte, keep the remaining 31 bytes,
        // left-padded back to 32 bytes with a leading zero byte.
        let shifted = [0x00] + digest.dropLast()
        return "0x" + hex(shifted)
    }

    private static func signalBytes(_ signal: String) -> [UInt8] {
        if signal.hasPrefix("0x") {
            let hexPart = String(signal.dropFirst(2))
            if hexPart.count % 2 == 0, let bytes = hexDecode(hexPart) {
                return bytes
            }
        }
        return Array(signal.utf8)
    }

    // MARK: - Auth

    public static func authSignatureMessage(authChallenge: [UInt8]) -> [UInt8] {
        tag("pupille:auth:v1") + authChallenge
    }

    public static func worldProofHash(exactResultJSONBytes: [UInt8]) -> [UInt8] {
        sha256(exactResultJSONBytes)
    }

    // MARK: - Hex helpers

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func hexDecode(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return bytes
    }
}
