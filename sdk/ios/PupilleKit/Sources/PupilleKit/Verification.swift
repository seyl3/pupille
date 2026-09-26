import CryptoKit
import Foundation

public struct VerificationCheck: Identifiable, Sendable, Equatable {
    public enum ID: String, Sendable {
        case human, author, capture, bytes, caption, commitment, signature, app
    }
    public let id: ID
    public let title: String
    public let passed: Bool
}

public struct Verification: Sendable, Equatable {
    public let checks: [VerificationCheck]
    public let handle: String?
    /// World environment of the author's Proof of Human.
    public let environment: WorldEnvironment?
    /// App Attest app ID the issuer certified the capture for.
    public let appID: String?

    /// True only when every check passed.
    public var isVerified: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
}

/// Offline verification against the issuer key. Same checks as `@pupille/verify` and the
/// Pupille app's proof sheet. Never trusts a "verified" flag from a server.
public enum ProofVerifier {
    private struct ProfileCertificate: Decodable {
        let profileId: String; let handle: String; let keyVersion: Int
        let publicKey: String; let credential: String; let environment: String?
    }
    private struct CaptureCertificate: Decodable {
        let appId: String?; let profileId: String; let keyVersion: Int
        let imageSha256: String; let depthSha256: String; let captionSha256: String?
        let challenge: String; let assertionSha256: String; let captureCommitment: String
    }

    public static func verify(_ proof: PupilleProof, imageData: Data,
                              issuerPublicKey: Data, trustedAppIDs: Set<String>? = nil) -> Verification {
        let issuer = try? Curve25519.Signing.PublicKey(rawRepresentation: issuerPublicKey)
        let profileBytes = Data(base64Encoded: proof.profileCert.certB64)
        let captureBytes = Data(base64Encoded: proof.captureCert.certB64)
        let profileSigned = issuer.flatMap { key in
            profileBytes.flatMap { bytes in Data(base64Encoded: proof.profileCert.sigB64).map { key.isValidSignature($0, for: bytes) } }
        } ?? false
        let captureSigned = issuer.flatMap { key in
            captureBytes.flatMap { bytes in Data(base64Encoded: proof.captureCert.sigB64).map { key.isValidSignature($0, for: bytes) } }
        } ?? false
        let profile = profileBytes.flatMap { try? JSONDecoder().decode(ProfileCertificate.self, from: $0) }
        let capture = captureBytes.flatMap { try? JSONDecoder().decode(CaptureCertificate.self, from: $0) }

        let imageDigest = Data(SHA256.hash(data: imageData))
        let noDepth = Data(repeating: 0, count: 32)
        let environment = profile?.environment.flatMap(WorldEnvironment.init(rawValue:))
        let worldCredential = profile?.credential == "proof_of_human" && environment != nil
        let authorMatches = profile != nil && profile?.handle == proof.author.handle
            && profile?.profileId == proof.author.profileId
            && profile?.publicKey == proof.author.publicKey
        let captureMatches = capture != nil && capture?.profileId == profile?.profileId
            && capture?.keyVersion == profile?.keyVersion
            && capture?.depthSha256 == noDepth.hex
        let bytesMatch = capture?.imageSha256 == imageDigest.hex
        let captionMatches: Bool
        if let caption = proof.caption, !caption.isEmpty {
            captionMatches = capture?.captionSha256 == Data(SHA256.hash(data: Data(caption.utf8))).hex
        } else {
            captionMatches = capture != nil && capture?.captionSha256 == nil
        }

        // Recompute the commitment from the bytes we hold, not the one the certificate states.
        var commitment: Data?
        if let profile, let capture,
           let profileID = Data(hex: profile.profileId),
           let publicKey = Data(base64Encoded: profile.publicKey),
           let challenge = Data(hex: capture.challenge),
           let assertionHash = Data(hex: capture.assertionSha256) {
            commitment = ProtocolHash.captureCommitment(imageHash: imageDigest, challenge: challenge,
                assertionHash: assertionHash, profileID: profileID, publicKey: publicKey)
        }
        let commitmentMatches = commitment != nil && commitment?.hex == capture?.captureCommitment
        var authorSigned = false
        if let commitment, let profile,
           let keyBytes = Data(base64Encoded: profile.publicKey),
           let key = try? P256.Signing.PublicKey(x963Representation: keyBytes),
           let signatureBytes = Data(base64Encoded: proof.postSignature),
           let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureBytes) {
            authorSigned = key.isValidSignature(signature, for: ProtocolHash.postSignatureMessage(commitment))
        }

        var checks = [
            VerificationCheck(id: .human, title: "World Human credential certified at signup", passed: profileSigned && worldCredential),
            VerificationCheck(id: .author, title: "Profile belongs to this author", passed: authorMatches),
            VerificationCheck(id: .capture, title: "Device capture certified by Pupille", passed: captureSigned && captureMatches),
            VerificationCheck(id: .bytes, title: "Exact photo bytes match", passed: bytesMatch),
            VerificationCheck(id: .caption, title: "Caption matches", passed: captionMatches),
            VerificationCheck(id: .commitment, title: "Capture commitment matches", passed: commitmentMatches),
            VerificationCheck(id: .signature, title: "Author signed this capture", passed: authorSigned),
        ]
        if let trustedAppIDs {
            checks.append(VerificationCheck(id: .app, title: "Captured in a trusted app",
                passed: captureSigned && capture?.appId.map(trustedAppIDs.contains) == true))
        }
        return Verification(checks: checks, handle: profile?.handle, environment: environment, appID: capture?.appId)
    }

    /// Verifies a JPEG that carries its own proof. `nil` when the file has no Pupille proof.
    public static func verify(file: Data, issuerPublicKey: Data, trustedAppIDs: Set<String>? = nil) throws -> Verification? {
        let (proof, imageData) = try ProofJPEG.extract(from: file)
        return proof.map { verify($0, imageData: imageData, issuerPublicKey: issuerPublicKey, trustedAppIDs: trustedAppIDs) }
    }
}
