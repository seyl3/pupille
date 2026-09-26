import CryptoKit
import Foundation

/// Byte-exact derivations from docs/ARCHITECTURE.md §06. They must match the backend.
enum ProtocolHash {
    static let noDepth = Data(repeating: 0, count: 32)

    private static func sha256(_ parts: Data...) -> Data {
        Data(SHA256.hash(data: parts.reduce(Data(), +)))
    }

    static func profileCommitment(profileID: Data, publicKey: Data, handle: String) -> Data {
        sha256(Data("pupille:profile:v1".utf8), profileID, publicKey, Data(handle.utf8))
    }

    static func profilePoPMessage(_ commitment: Data) -> Data {
        Data("pupille:profile-sig:v1".utf8) + commitment
    }

    static func profileAssertClientDataHash(_ commitment: Data) -> Data {
        sha256(Data("pupille:profile-assert:v1".utf8), commitment)
    }

    static func captureClientDataHash(imageHash: Data, challenge: Data) -> Data {
        sha256(Data("pupille:assert:v1".utf8), imageHash, noDepth, challenge)
    }

    static func captureCommitment(imageHash: Data, challenge: Data, assertionHash: Data,
                                  profileID: Data, publicKey: Data) -> Data {
        sha256(Data("pupille:capture:v1".utf8), imageHash, noDepth, challenge, assertionHash, profileID, publicKey)
    }

    static func postSignatureMessage(_ commitment: Data) -> Data {
        Data("pupille:post-sig:v1".utf8) + commitment
    }
}
