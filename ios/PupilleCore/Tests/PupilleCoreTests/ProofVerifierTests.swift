import XCTest
@testable import PupilleCore
import Crypto
import Foundation

final class ProofVerifierTests: XCTestCase {
    /// Builds one fully-valid, self-consistent post + certs signed by a fresh issuer key,
    /// so each test can start from something the verifier accepts and then corrupt one thing.
    struct Fixture {
        let issuerPrivateKey: Curve25519.Signing.PrivateKey
        let issuerPublicKey: Curve25519.Signing.PublicKey
        let profileKey: SoftwareProfileKey
        let profileId: [UInt8]
        let imageBytes: [UInt8]
        let challenge: [UInt8]
        let assertion: [UInt8]
        let post: PostPayload
    }

    static func makeValidFixture() throws -> Fixture {
        let issuerKey = Curve25519.Signing.PrivateKey()
        let profileKey = SoftwareProfileKey()
        let profileId = (0..<16).map { UInt8($0 + 0x40) }
        let handle = "xyz"
        let publicKeyX963 = profileKey.publicKeyX963

        let profileCertJSON: [String: Any] = [
            "v": 1, "type": "profile", "profileId": CaptureHasher.hex(profileId),
            "handle": handle, "keyVersion": 1,
            "publicKey": Data(publicKeyX963).base64EncodedString(),
            "uniquenessAction": "pupille-profile-v1", "worldSession": true,
            "profileCommitment": CaptureHasher.hex(
                CaptureHasher.profileCommitment(profileId: profileId, profilePublicKey: publicKeyX963, handle: handle)
            )
        ]
        let profileCertBytes = try JSONSerialization.data(withJSONObject: profileCertJSON, options: [.sortedKeys])
        let profileCertSig = try issuerKey.signature(for: profileCertBytes)

        let imageBytes = Array("test-image-bytes".utf8)
        let challenge = (0..<32).map { UInt8($0) }
        let assertion = Array("test-assertion".utf8)
        let imageHash = CaptureHasher.imageHash(imageBytes: imageBytes)
        let depthHash = CaptureHasher.depthHash(depthBytes: nil)
        let assertionHash = CaptureHasher.assertionHash(assertion: assertion)
        let captureCommitment = CaptureHasher.captureCommitment(
            imageHash: imageHash, depthHash: depthHash, challenge: challenge,
            assertionHash: assertionHash, profileId: profileId, profilePublicKey: publicKeyX963
        )
        let postSignature = try profileKey.sign(CaptureHasher.postSignatureMessage(captureCommitment: captureCommitment))

        let captureCertJSON: [String: Any] = [
            "v": 1, "type": "capture", "postId": "post1",
            "appId": "test.pupille", "profileId": CaptureHasher.hex(profileId), "keyVersion": 1,
            "imageSha256": CaptureHasher.hex(imageHash), "depthSha256": CaptureHasher.hex(depthHash),
            "captionSha256": NSNull(), "challenge": CaptureHasher.hex(challenge),
            "assertionSha256": CaptureHasher.hex(assertionHash),
            "captureCommitment": CaptureHasher.hex(captureCommitment)
        ]
        let captureCertBytes = try JSONSerialization.data(withJSONObject: captureCertJSON, options: [.sortedKeys])
        let captureCertSig = try issuerKey.signature(for: captureCertBytes)

        let post = PostPayload(
            imageBytes: imageBytes, depthBytes: nil, captionBytes: nil,
            authorHandle: handle, authorPublicKeyX963: publicKeyX963, authorProfileId: profileId,
            postSignature: postSignature,
            profileCert: SignedBlob(certBytes: Array(profileCertBytes), signature: Array(profileCertSig)),
            captureCert: SignedBlob(certBytes: Array(captureCertBytes), signature: Array(captureCertSig))
        )

        return Fixture(
            issuerPrivateKey: issuerKey, issuerPublicKey: issuerKey.publicKey, profileKey: profileKey,
            profileId: profileId, imageBytes: imageBytes, challenge: challenge, assertion: assertion, post: post
        )
    }

    func testValidPostVerifies() throws {
        let f = try Self.makeValidFixture()
        XCTAssertEqual(ProofVerifier.verify(post: f.post, issuerPublicKey: f.issuerPublicKey), .verified)
    }

    /// Demo attack 1: flip one byte of the downloaded image. Check 4 must catch it.
    func testFlippedImageByteFailsVerification() throws {
        let f = try Self.makeValidFixture()
        var corruptedImage = f.post.imageBytes
        corruptedImage[0] ^= 0xFF
        let corrupted = PostPayload(
            imageBytes: corruptedImage, depthBytes: f.post.depthBytes, captionBytes: f.post.captionBytes,
            authorHandle: f.post.authorHandle, authorPublicKeyX963: f.post.authorPublicKeyX963,
            authorProfileId: f.post.authorProfileId, postSignature: f.post.postSignature,
            profileCert: f.post.profileCert, captureCert: f.post.captureCert
        )
        XCTAssertEqual(ProofVerifier.verify(post: corrupted, issuerPublicKey: f.issuerPublicKey), .unverified(.imageBytesMismatch))
    }

    /// Demo attack 2: relabel the post as a different author (different profile cert / key),
    /// while keeping the original image and capture cert. Checks 2/6 must catch it.
    func testRelabelledAuthorFailsVerification() throws {
        let f = try Self.makeValidFixture()
        let otherKey = SoftwareProfileKey()
        let relabelled = PostPayload(
            imageBytes: f.post.imageBytes, depthBytes: f.post.depthBytes, captionBytes: f.post.captionBytes,
            authorHandle: f.post.authorHandle,
            authorPublicKeyX963: otherKey.publicKeyX963, // swapped key, cert still says the original
            authorProfileId: f.post.authorProfileId, postSignature: f.post.postSignature,
            profileCert: f.post.profileCert, captureCert: f.post.captureCert
        )
        let result = ProofVerifier.verify(post: relabelled, issuerPublicKey: f.issuerPublicKey)
        XCTAssertEqual(result, .unverified(.authorMismatch))
    }

    /// Demo attack 3: copy a valid certificate onto another image's bytes. Check 4 must catch it
    /// (the certificate's imageSha256 no longer matches the downloaded bytes).
    func testCertificateCopiedOntoAnotherImageFailsVerification() throws {
        let f = try Self.makeValidFixture()
        let anotherImage = Array("a completely different image".utf8)
        let withCopiedCert = PostPayload(
            imageBytes: anotherImage, depthBytes: f.post.depthBytes, captionBytes: f.post.captionBytes,
            authorHandle: f.post.authorHandle, authorPublicKeyX963: f.post.authorPublicKeyX963,
            authorProfileId: f.post.authorProfileId, postSignature: f.post.postSignature,
            profileCert: f.post.profileCert, captureCert: f.post.captureCert // cert copied unchanged
        )
        XCTAssertEqual(ProofVerifier.verify(post: withCopiedCert, issuerPublicKey: f.issuerPublicKey), .unverified(.imageBytesMismatch))
    }

    func testForgedPostSignatureFailsVerification() throws {
        let f = try Self.makeValidFixture()
        var forgedSig = f.post.postSignature
        forgedSig[0] ^= 0xFF
        let forged = PostPayload(
            imageBytes: f.post.imageBytes, depthBytes: f.post.depthBytes, captionBytes: f.post.captionBytes,
            authorHandle: f.post.authorHandle, authorPublicKeyX963: f.post.authorPublicKeyX963,
            authorProfileId: f.post.authorProfileId, postSignature: forgedSig,
            profileCert: f.post.profileCert, captureCert: f.post.captureCert
        )
        XCTAssertEqual(ProofVerifier.verify(post: forged, issuerPublicKey: f.issuerPublicKey), .unverified(.postSignatureInvalid))
    }

    func testTamperedIssuerSignatureOnProfileCertFailsVerification() throws {
        let f = try Self.makeValidFixture()
        var tamperedSig = f.post.profileCert.signature
        tamperedSig[0] ^= 0xFF
        let tamperedCert = SignedBlob(certBytes: f.post.profileCert.certBytes, signature: tamperedSig)
        let post = PostPayload(
            imageBytes: f.post.imageBytes, depthBytes: f.post.depthBytes, captionBytes: f.post.captionBytes,
            authorHandle: f.post.authorHandle, authorPublicKeyX963: f.post.authorPublicKeyX963,
            authorProfileId: f.post.authorProfileId, postSignature: f.post.postSignature,
            profileCert: tamperedCert, captureCert: f.post.captureCert
        )
        XCTAssertEqual(ProofVerifier.verify(post: post, issuerPublicKey: f.issuerPublicKey), .unverified(.profileCertSignatureInvalid))
    }
}
