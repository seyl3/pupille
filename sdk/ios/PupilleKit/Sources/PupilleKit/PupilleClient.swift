import CryptoKit
import DeviceCheck
import Foundation
import IDKit

/// The entry point for host apps.
///
///     let pupille = PupilleClient(configuration: config)
///
///     // Once per device: Secure Enclave key + App Attest + World ID Proof of Human
///     let request = try await pupille.beginEnrollment(handle: "xyz")
///     openURL(request.approvalURL)
///     let enrollment = try await request.result()
///
///     // Every photo: only PupilleCameraView can produce a CapturedPhoto
///     let postID = try await pupille.publish(photo, caption: "hello")
///
///     // Anywhere: exact bytes checked against the issuer key, on this device
///     let posts = try await pupille.loadFeed()
@MainActor
public final class PupilleClient {
    public var configuration: PupilleConfiguration
    private let session: URLSession

    public init(configuration: PupilleConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    var api: APIClient { APIClient(baseURL: configuration.backendURL, session: session) }
    var identity: DeviceIdentity { DeviceIdentity(defaults: configuration.defaults) }

    /// The handle this device enrolled, or `nil` before enrollment completes.
    public var enrolledHandle: String? { identity.handle }

    /// Forgets this device's enrollment locally. The backend keeps its records.
    public func signOut() { identity.forget() }

    // MARK: - Enrollment

    /// Registers the App Attest key, creates the Secure Enclave key, has the backend check
    /// both (one Face ID prompt), then prepares the World ID Proof of Human request.
    /// The World signal commits to the device key and the handle.
    public func beginEnrollment(handle: String) async throws -> WorldIDVerification {
        struct RPFields: Decodable { let nonce: String; let createdAt: UInt64; let expiresAt: UInt64; let sig: String }
        struct Start: Decodable { let reservationId: String; let rpContext: RPFields; let worldSignal: String; let environment: String }
        struct Preflight: Decodable { let deviceVerified: Bool }

        let api = api
        let identity = identity
        let attest = try await identity.registeredAttestKey(api: api)
        let key = try identity.profileKey()
        let id = try identity.profileID()
        let publicKey = key.publicKey.x963Representation
        let normalized = handle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let start: Start = try await api.post("/v1/onboard/start", [
            "profileId": id.hex, "publicKey": publicKey.hex,
            "handle": normalized, "attestKeyId": attest.serverID
        ])
        guard let environment = WorldEnvironment(rawValue: start.environment) else { throw PupilleError.invalidResponse }

        let commitment = ProtocolHash.profileCommitment(profileID: id, publicKey: publicKey, handle: normalized)
        let pop = try key.signature(for: ProtocolHash.profilePoPMessage(commitment)).rawRepresentation
        let assertion = try await DCAppAttestService.shared.generateAssertion(attest.appleID,
            clientDataHash: ProtocolHash.profileAssertClientDataHash(commitment))
        let preflight: Preflight = try await api.post("/v1/onboard/device", [
            "reservationId": start.reservationId,
            "profilePoP": pop.hex,
            "assertionBase64": assertion.base64EncodedString()
        ])
        guard preflight.deviceVerified else { throw PupilleError.invalidResponse }

        let context = try RpContext(rpId: configuration.worldRPID, nonce: start.rpContext.nonce,
            createdAt: start.rpContext.createdAt, expiresAt: start.rpContext.expiresAt,
            signature: start.rpContext.sig)
        let config = IDKitRequestConfig(appId: configuration.worldAppID, action: configuration.worldAction,
            rpContext: context, actionDescription: configuration.worldActionDescription,
            allowLegacyProofs: false,
            environment: environment == .staging ? .staging : .production)
        let request = try IDKit.request(config: config).preset(.proofOfHuman(signal: start.worldSignal))
        return WorldIDVerification(client: self, request: request,
            reservationID: start.reservationId, environment: environment)
    }

    // MARK: - Publishing

    /// Binds the photo to a fresh backend challenge, an App Attest assertion and a Face ID
    /// signature by the enrolled key, then publishes it. Returns the post ID.
    public func publish(_ photo: CapturedPhoto, caption: String) async throws -> String {
        struct Challenge: Decodable { let challengeId: String; let challenge: String }
        struct DeviceAccepted: Decodable { let worldSignal: String }
        struct Published: Decodable { let postId: String }

        let api = api
        let identity = identity
        guard identity.handle != nil, let profileID = identity.storedProfileID,
              let attestKeyID = identity.storedAttestKeyID else {
            throw PupilleError.notEnrolled
        }
        let key = try identity.profileKey()
        let publicKey = key.publicKey.x963Representation
        let challenge: Challenge = try await api.post("/v1/captures/challenge", [:],
            headers: ["x-profile-id": profileID.hex])
        guard let challengeBytes = Data(hex: challenge.challenge), challengeBytes.count == 32 else {
            throw PupilleError.invalidResponse
        }
        let imageHash = Data(SHA256.hash(data: photo.imageData))
        let assertion = try await DCAppAttestService.shared.generateAssertion(attestKeyID,
            clientDataHash: ProtocolHash.captureClientDataHash(imageHash: imageHash, challenge: challengeBytes))
        let commitment = ProtocolHash.captureCommitment(imageHash: imageHash, challenge: challengeBytes,
            assertionHash: Data(SHA256.hash(data: assertion)), profileID: profileID, publicKey: publicKey)
        let signature = try key.signature(for: ProtocolHash.postSignatureMessage(commitment)).rawRepresentation
        let _: DeviceAccepted = try await api.post("/v1/captures/\(challenge.challengeId)/device", [
            "imageBase64": photo.imageData.base64EncodedString(),
            "assertionBase64": assertion.base64EncodedString(),
            "postSignature": signature.hex,
            "profilePublicKey": publicKey.hex
        ])
        let published: Published = try await api.post("/v1/captures/\(challenge.challengeId)/publish", [
            "caption": caption
        ])
        return published.postId
    }

    // MARK: - Feed and verification

    /// Fetches the feed and each post's exact bytes, and verifies every post on this device.
    public func loadFeed() async throws -> [VerifiedPost] {
        let api = api
        let viewer = identity.storedProfileID.map { ["x-profile-id": $0.hex] } ?? [:]
        let posts: [FeedPost] = try await api.get("/v1/feed", headers: viewer)
        var avatars: [String: Data] = [:]
        var verified: [VerifiedPost] = []
        for post in posts {
            let image = try? await api.bytes(post.imageUrl)
            if let avatarURL = post.author.avatarUrl, avatars[post.author.handle] == nil {
                avatars[post.author.handle] = try? await api.bytes(avatarURL)
            }
            verified.append(VerifiedPost(post: post, imageData: image, avatarData: avatars[post.author.handle],
                verification: image.map { verify(PupilleProof(post), imageData: $0) }
                    ?? Verification(checks: [], handle: nil, environment: nil, appID: nil)))
        }
        return verified
    }

    /// Checks a proof against the configured issuer key and trusted apps.
    public func verify(_ proof: PupilleProof, imageData: Data) -> Verification {
        ProofVerifier.verify(proof, imageData: imageData,
            issuerPublicKey: configuration.issuerPublicKey, trustedAppIDs: configuration.trustedAppIDs)
    }

    /// Checks a JPEG that carries its own proof. `nil` when the file has none.
    public func verify(file: Data) throws -> Verification? {
        try ProofVerifier.verify(file: file,
            issuerPublicKey: configuration.issuerPublicKey, trustedAppIDs: configuration.trustedAppIDs)
    }
}

/// A pending World ID Proof of Human request. Open `approvalURL`, then await `result()`.
@MainActor
public final class WorldIDVerification: Identifiable {
    public nonisolated let id = UUID()
    public let environment: WorldEnvironment
    /// The IDKit connector URL.
    public let connectorURL: URL
    private let client: PupilleClient
    private let request: IDKitRequest
    private let reservationID: String

    init(client: PupilleClient, request: IDKitRequest, reservationID: String, environment: WorldEnvironment) {
        self.client = client
        self.request = request
        self.reservationID = reservationID
        self.environment = environment
        self.connectorURL = request.connectorURL
    }

    /// Where to send the user: World App in production, World Simulator in staging.
    public var approvalURL: URL {
        guard environment == .staging else { return connectorURL }
        var simulator = URLComponents(string: "https://simulator.worldcoin.org/")
        simulator?.queryItems = [URLQueryItem(name: "connect_url", value: connectorURL.absoluteString)]
        return simulator?.url ?? connectorURL
    }

    /// Waits for the user to approve in World App, then has the backend verify the proof
    /// with World and store the profile.
    public func result() async throws -> Enrollment {
        struct Complete: Decodable { let handle: String; let profileId: String }

        switch await request.pollUntilCompletion() {
        case .failure(let reason):
            throw PupilleError.worldProofFailed(reason.rawValue)
        case .success(let result):
            let json = try idkitResultToJson(result: result)
            guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw PupilleError.invalidResponse
            }
            let completed: Complete = try await client.api.post("/v1/onboard/complete", [
                "reservationId": reservationID, "result": object
            ])
            client.identity.handle = completed.handle
            return Enrollment(handle: completed.handle, profileID: completed.profileId, environment: environment)
        }
    }
}

public struct Enrollment: Sendable {
    public let handle: String
    public let profileID: String
    public let environment: WorldEnvironment
}
