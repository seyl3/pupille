import Foundation

/// Everything a verifier needs besides the image bytes. Same JSON as `@pupille/verify`.
public struct PupilleProof: Codable, Sendable, Equatable {
    public var v = 1
    public var type = "pupille-proof"
    public let postId: String
    public let caption: String?
    public let createdAt: String?
    public let author: Author
    /// Base64 raw r‖s ECDSA P-256 signature by the author's Secure Enclave key.
    public let postSignature: String
    public let profileCert: SignedCertificate
    public let captureCert: SignedCertificate

    public struct Author: Codable, Sendable, Equatable {
        public let handle: String
        public let profileId: String
        public let publicKey: String
    }

    public init(_ post: FeedPost) {
        postId = post.id
        caption = post.caption
        createdAt = post.createdAt
        author = Author(handle: post.author.handle, profileId: post.author.profileId, publicKey: post.author.publicKey)
        postSignature = post.postSignature
        profileCert = post.profileCert
        captureCert = post.captureCert
    }
}

/// Issuer-signed JSON certificate, as exact base64 bytes plus an Ed25519 signature.
public struct SignedCertificate: Codable, Sendable, Equatable {
    public let certB64: String
    public let sigB64: String
}

/// A post as returned by `GET /v1/feed`.
public struct FeedPost: Decodable, Identifiable, Sendable {
    public let id: String
    public let imageUrl: String
    public let caption: String?
    public let author: Author
    public let postSignature: String
    public let profileCert: SignedCertificate
    public let captureCert: SignedCertificate
    public let createdAt: String?

    public struct Author: Decodable, Sendable {
        public let handle: String
        public let profileId: String
        public let publicKey: String
        public let avatarUrl: String?
    }
}

/// A feed post with the exact bytes it was checked against and the outcome.
public struct VerifiedPost: Identifiable, Sendable {
    public let post: FeedPost
    public let imageData: Data?
    public let verification: Verification
    public var id: String { post.id }

    /// A JPEG that carries its own proof, for sharing outside the app.
    public func shareableJPEG() throws -> Data? {
        guard let imageData else { return nil }
        return try ProofJPEG.embed(PupilleProof(post), in: imageData)
    }
}
