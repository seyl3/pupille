import Crypto
import Foundation

/// Pure function implementing docs/ARCHITECTURE.md §09, checks 1-7. Runs on every post
/// before the feed draws its badge. Never trusts a `verified` field from the server —
/// every check is recomputed from the downloaded bytes and the pinned issuer key.
public enum ProofVerifier {
    public enum Reason: Equatable, Sendable {
        case profileCertSignatureInvalid          // check 1
        case authorMismatch                       // check 2: swapped author
        case captureCertSignatureInvalid          // check 3: forged/mismatched cert
        case imageBytesMismatch                   // check 4: edited image / cert copied onto another image
        case depthBytesMismatch                   // check 4 (depth)
        case captureCommitmentMismatch            // check 5: inconsistent cert
        case postSignatureInvalid                 // check 6: authorship forged
        case captionMismatch                      // check 7
    }

    public enum Result: Equatable, Sendable {
        case verified
        case unverified(Reason)
    }

    public static func verify(
        post: PostPayload,
        issuerPublicKey: Curve25519.Signing.PublicKey
    ) -> Result {
        // Check 1: profile cert signed under the pinned issuer key.
        guard post.profileCert.verify(issuerPublicKey: issuerPublicKey) else {
            return .unverified(.profileCertSignatureInvalid)
        }
        guard let profileFields = try? JSONDecoder().decode(ProfileCertFields.self, from: Data(post.profileCert.certBytes)) else {
            return .unverified(.profileCertSignatureInvalid)
        }

        // Check 2: swapped author — cert's key/handle/profileId must match the post's claimed author.
        guard
            let certPublicKey = CaptureHasher.hexDecode(base64ToHex(profileFields.publicKey) ?? ""),
            certPublicKey == post.authorPublicKeyX963,
            profileFields.handle == post.authorHandle,
            CaptureHasher.hexDecode(profileFields.profileId) == post.authorProfileId
        else {
            return .unverified(.authorMismatch)
        }

        // Check 3: capture cert signed under the pinned issuer key.
        guard post.captureCert.verify(issuerPublicKey: issuerPublicKey) else {
            return .unverified(.captureCertSignatureInvalid)
        }
        guard let captureFields = try? JSONDecoder().decode(CaptureCertFields.self, from: Data(post.captureCert.certBytes)) else {
            return .unverified(.captureCertSignatureInvalid)
        }
        guard
            captureFields.profileId == profileFields.profileId,
            captureFields.keyVersion == profileFields.keyVersion
        else {
            return .unverified(.captureCertSignatureInvalid)
        }

        // Check 4: exact downloaded bytes must hash to what the certificate says.
        let imageHash = CaptureHasher.imageHash(imageBytes: post.imageBytes)
        guard CaptureHasher.hex(imageHash) == captureFields.imageSha256 else {
            return .unverified(.imageBytesMismatch)
        }
        let depthHash = CaptureHasher.depthHash(depthBytes: post.depthBytes)
        guard CaptureHasher.hex(depthHash) == captureFields.depthSha256 else {
            return .unverified(.depthBytesMismatch)
        }

        // Check 5: recomputed captureCommitment must equal the certified one.
        guard
            let challenge = CaptureHasher.hexDecode(captureFields.challenge),
            let assertionHash = CaptureHasher.hexDecode(captureFields.assertionSha256),
            let profileId = CaptureHasher.hexDecode(profileFields.profileId)
        else {
            return .unverified(.captureCommitmentMismatch)
        }
        let recomputedCommitment = CaptureHasher.captureCommitment(
            imageHash: imageHash, depthHash: depthHash, challenge: challenge,
            assertionHash: assertionHash, profileId: profileId, profilePublicKey: post.authorPublicKeyX963
        )
        guard CaptureHasher.hex(recomputedCommitment) == captureFields.captureCommitment else {
            return .unverified(.captureCommitmentMismatch)
        }

        // Check 6: postSignature verifies under the profile public key over the tagged commitment.
        // This is the check that catches authorship forged by anyone, including the server.
        let postSigMessage = CaptureHasher.postSignatureMessage(captureCommitment: recomputedCommitment)
        guard ProfileKeyVerifier.verify(
            signature: post.postSignature, message: postSigMessage, publicKeyX963: post.authorPublicKeyX963
        ) else {
            return .unverified(.postSignatureInvalid)
        }

        // Check 7 (optional): caption hash, if present in both the payload and the cert.
        if let captionBytes = post.captionBytes {
            let captionHash = CaptureHasher.hex(CaptureHasher.sha256(captionBytes))
            guard captionHash == captureFields.captionSha256 else {
                return .unverified(.captionMismatch)
            }
        }

        return .verified
    }

    /// Decodes a base64 X9.63 public key string into lowercase hex, for comparing against
    /// a hex-decoded byte array. Returns nil on malformed base64.
    private static func base64ToHex(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return CaptureHasher.hex(Array(data))
    }
}
