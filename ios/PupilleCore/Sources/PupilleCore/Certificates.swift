import Crypto
import Foundation

/// Mirrors docs/ARCHITECTURE.md §10. Both certificates are exact bytes (`certB64` + `sigB64`),
/// signed once by the issuer's Ed25519 key, and never re-serialized.
public struct SignedBlob: Sendable {
    public let certBytes: [UInt8]
    public let signature: [UInt8]

    public init(certBytes: [UInt8], signature: [UInt8]) {
        self.certBytes = certBytes
        self.signature = signature
    }

    public func verify(issuerPublicKey: Curve25519.Signing.PublicKey) -> Bool {
        issuerPublicKey.isValidSignature(Data(signature), for: Data(certBytes))
    }
}

/// Decoded fields read out of a profile certificate's JSON, per §10. Only the fields
/// ProofVerifier needs are modeled; the cert is otherwise treated as opaque signed bytes.
public struct ProfileCertFields: Decodable {
    public let v: Int
    public let type: String
    public let profileId: String
    public let handle: String
    public let keyVersion: Int
    public let publicKey: String // base64 X9.63
    public let uniquenessAction: String
    public let worldSession: Bool
    public let profileCommitment: String
}

/// Decoded fields read out of a capture certificate's JSON, per §10.
public struct CaptureCertFields: Decodable {
    public let v: Int
    public let type: String
    public let postId: String
    public let appId: String
    public let profileId: String
    public let keyVersion: Int
    public let imageSha256: String
    public let depthSha256: String
    public let captionSha256: String?
    public let challenge: String
    public let assertionSha256: String
    public let captureCommitment: String
}

/// The post payload as returned by `GET /v1/feed`, per §10.
public struct PostPayload {
    public let imageBytes: [UInt8]
    public let depthBytes: [UInt8]?
    public let captionBytes: [UInt8]?
    public let authorHandle: String
    public let authorPublicKeyX963: [UInt8]
    public let authorProfileId: [UInt8]
    public let postSignature: [UInt8]
    public let profileCert: SignedBlob
    public let captureCert: SignedBlob

    public init(
        imageBytes: [UInt8], depthBytes: [UInt8]?, captionBytes: [UInt8]?,
        authorHandle: String, authorPublicKeyX963: [UInt8], authorProfileId: [UInt8],
        postSignature: [UInt8], profileCert: SignedBlob, captureCert: SignedBlob
    ) {
        self.imageBytes = imageBytes
        self.depthBytes = depthBytes
        self.captionBytes = captionBytes
        self.authorHandle = authorHandle
        self.authorPublicKeyX963 = authorPublicKeyX963
        self.authorProfileId = authorProfileId
        self.postSignature = postSignature
        self.profileCert = profileCert
        self.captureCert = captureCert
    }
}
