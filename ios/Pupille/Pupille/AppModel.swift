import CryptoKit
import DeviceCheck
import Foundation
import IDKit
import LocalAuthentication
import Security

struct FeedPost: Decodable, Identifiable {
    let id: String
    let imageUrl: String
    let caption: String?
    let author: Author
    let postSignature: String
    let profileCert: Certificate
    let captureCert: Certificate
    let createdAt: String
    let reactions: ReactionCounts
    let myReaction: String?
    struct Author: Decodable {
        let handle: String; let profileId: String; let publicKey: String; let avatarUrl: String?
    }
    struct Certificate: Decodable { let certB64: String; let sigB64: String }
}

struct ReactionCounts: Decodable {
    let nerd: Int; let heart: Int; let aubergine: Int; let japan: Int
    subscript(_ kind: String) -> Int {
        switch kind {
        case "nerd": nerd
        case "heart": heart
        case "aubergine": aubergine
        default: japan
        }
    }
}

struct VerificationCheck: Identifiable {
    let title: String
    let passed: Bool
    var id: String { title }
}

private struct ProfileCertificate: Decodable {
    let profileId: String; let handle: String; let keyVersion: Int
    let publicKey: String; let credential: String; let environment: String?
}
private struct CaptureCertificate: Decodable {
    let profileId: String; let keyVersion: Int
    let imageSha256: String; let depthSha256: String
    let captionSha256: String?; let challenge: String
    let assertionSha256: String; let captureCommitment: String
}

private struct AttestChallenge: Decodable { let challengeId: String; let challenge: String }
private struct AttestStatus: Decodable { let registered: Bool }
private struct AttestRegistered: Decodable { let keyId: String }
private struct StartSignup: Decodable {
    let reservationId: String
    let rpContext: RPFields
    let worldSignal: String
    let environment: String
}
private struct RPFields: Decodable {
    let nonce: String
    let createdAt: UInt64
    let expiresAt: UInt64
    let sig: String
}
private struct CompleteSignup: Decodable { let handle: String; let profileId: String }
private struct DevicePreflight: Decodable { let deviceVerified: Bool }
private struct CaptureChallenge: Decodable { let challengeId: String; let challenge: String }
private struct PublishResponse: Decodable { let postId: String }
private struct AvatarChallenge: Decodable { let challengeId: String; let challenge: String }
private struct AvatarUploaded: Decodable { let avatarUrl: String }
private struct ReactionChallenge: Decodable { let challengeId: String; let challenge: String }
private struct ReactionResult: Decodable { let reactions: ReactionCounts; let myReaction: String }
private struct DemoResetChallenge: Decodable { let challengeId: String; let challenge: String }
private struct DemoResetResult: Decodable { let reset: Bool }
struct ProfileSummary: Decodable {
    let handle: String; let avatarUrl: String?; let postCount: Int; let joinedAt: String
    let certs: [ProfileCertEntry]
}
struct ProfileCertEntry: Decodable {
    let keyVersion: Int; let certB64: String; let sigB64: String
}
private struct DeviceAccepted: Decodable { let worldSignal: String }
private struct APIError: Decodable { let error: String }

@MainActor
final class AppModel: ObservableObject {
    @Published var handle: String = UserDefaults.standard.string(forKey: "profileHandle") ?? ""
    @Published var posts: [FeedPost] = []
    @Published var imageBytes: [String: Data] = [:]
    @Published var avatarBytes: [String: Data] = [:]
    @Published var profile: ProfileSummary?
    @Published var publicProfiles: [String: ProfileSummary] = [:]
    @Published var verifiedPostIDs: Set<String> = []
    @Published var verificationChecks: [String: [VerificationCheck]] = [:]
    @Published var reactionCounts: [String: ReactionCounts] = [:]
    @Published var myReactions: [String: String] = [:]
    @Published var reactingPostIDs: Set<String> = []
    @Published var postEnvironments: [String: String] = [:]
    @Published var status = ""
    @Published var isBusy = false
    @Published var connectorURL: URL?
    @Published var worldRequestActive = false
    @Published var worldEnvironment = "staging"

    private let appID = "app_28d96ebb9f1fea8424710dd817901dcd"
    private let rpID = "rp_53e28a7c639fa2a7"
    private let issuerPublicKeyHex = "46699f0e689eb90902f3a7f3850b7dde146b77389161e3a1caa8d8062da92fb8"
    private var request: IDKitRequest?
    private var signup: StartSignup?

    var baseURL: String {
        get { UserDefaults.standard.string(forKey: "prodBackendURL") ?? "http://mac.local:8787" }
        set { UserDefaults.standard.set(newValue, forKey: "prodBackendURL"); objectWillChange.send() }
    }

    func loadFeed() async {
        do {
            let profileID = UserDefaults.standard.string(forKey: "profileID")
            posts = try await get("/v1/feed", headers: profileID.map { ["x-profile-id": $0] } ?? [:])
            verifiedPostIDs = []
            verificationChecks = [:]
            postEnvironments = [:]
            reactionCounts = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0.reactions) })
            myReactions = Dictionary(uniqueKeysWithValues: posts.compactMap {
                post in post.myReaction.map { (post.id, $0) }
            })
            for post in posts {
                let (image, response) = try await URLSession.shared.data(from: url(post.imageUrl))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                imageBytes[post.id] = image
                let checks = audit(post: post, image: image)
                verificationChecks[post.id] = checks
                if checks.allSatisfy(\.passed) {
                    verifiedPostIDs.insert(post.id)
                    if let certBytes = Data(base64Encoded: post.profileCert.certB64),
                       let profile = try? JSONDecoder().decode(ProfileCertificate.self, from: certBytes) {
                        postEnvironments[post.id] = profile.environment ?? "unknown"
                    }
                }
                if let avatarUrl = post.author.avatarUrl, avatarBytes[post.author.handle] == nil,
                   let (avatar, response) = try? await URLSession.shared.data(from: url(avatarUrl)),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    avatarBytes[post.author.handle] = avatar
                }
            }
        }
        catch { status = "Feed: \(error.localizedDescription)" }
    }

    func react(to postId: String, kind: String) async {
        guard !reactingPostIDs.contains(postId),
              ["nerd", "heart", "aubergine", "japan"].contains(kind) else { return }
        reactingPostIDs.insert(postId)
        defer { reactingPostIDs.remove(postId) }
        do {
            guard let profileHex = UserDefaults.standard.string(forKey: "profileID"),
                  let attestKeyID = UserDefaults.standard.string(forKey: "registeredAttestKeyID") else {
                throw AppError.server("Create your profile first")
            }
            let challenge: ReactionChallenge = try await post("/v1/posts/\(postId)/reaction/challenge", [
                "profileId": profileHex,
            ])
            guard let nonce = Data(hexString: challenge.challenge), nonce.count == 32 else {
                throw AppError.invalidResponse
            }
            let hash = Data(SHA256.hash(data: Data("pupille:reaction:v1".utf8)
                + Data(postId.utf8) + Data(kind.utf8) + nonce))
            let assertion = try await DCAppAttestService.shared.generateAssertion(attestKeyID, clientDataHash: hash)
            let result: ReactionResult = try await post("/v1/posts/\(postId)/reaction", [
                "challengeId": challenge.challengeId,
                "reaction": kind,
                "assertionBase64": assertion.base64EncodedString(),
            ])
            reactionCounts[postId] = result.reactions
            myReactions[postId] = result.myReaction
        } catch { status = "Reaction failed: \(error.localizedDescription)" }
    }

    func loadProfile() async {
        guard !handle.isEmpty else { return }
        do {
            let loaded: ProfileSummary = try await get("/v1/profiles/\(handle)")
            profile = loaded
            if let avatarUrl = loaded.avatarUrl,
               let (avatar, response) = try? await URLSession.shared.data(from: url(avatarUrl)),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                avatarBytes[handle] = avatar
            }
        } catch AppError.server(let message) where message == "HTTP 404" {
            clearLocalIdentity()
            status = "The demo server was reset. Create a new profile to continue."
        } catch { status = "Profile: \(error.localizedDescription)" }
    }

    func loadPublicProfile(_ handle: String) async {
        do {
            let loaded: ProfileSummary = try await get("/v1/profiles/\(handle)")
            publicProfiles[handle] = loaded
            if let avatarUrl = loaded.avatarUrl,
               let (avatar, response) = try? await URLSession.shared.data(from: url(avatarUrl)),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                avatarBytes[handle] = avatar
            }
        } catch { status = "Profile: \(error.localizedDescription)" }
    }

    func hasVerifiedHumanCertificate(_ summary: ProfileSummary) -> Bool {
        guard let issuerBytes = Data(hexString: issuerPublicKeyHex),
              let issuer = try? Curve25519.Signing.PublicKey(rawRepresentation: issuerBytes) else { return false }
        return summary.certs.contains { entry in
            guard let bytes = Data(base64Encoded: entry.certB64),
                  let signature = Data(base64Encoded: entry.sigB64),
                  issuer.isValidSignature(signature, for: bytes),
                  let cert = try? JSONDecoder().decode(ProfileCertificate.self, from: bytes) else { return false }
            return cert.handle == summary.handle && cert.keyVersion == entry.keyVersion
                && cert.credential == "proof_of_human"
                && ["staging", "production"].contains(cert.environment ?? "")
        }
    }

    func uploadAvatar(_ image: Data) async {
        isBusy = true
        status = "Approving profile photo with Face ID…"
        defer { isBusy = false }
        do {
            guard let profileHex = UserDefaults.standard.string(forKey: "profileID"),
                  let profileID = Data(hexString: profileHex) else {
                throw AppError.server("Create your profile first")
            }
            let key = try persistentProfileKey()
            let challenge: AvatarChallenge = try await post("/v1/profiles/avatar/challenge", ["profileId": profileHex])
            guard let nonce = Data(hexString: challenge.challenge), nonce.count == 32 else {
                throw AppError.invalidResponse
            }
            let message = Data("pupille:avatar:v1".utf8) + nonce
                + Data(SHA256.hash(data: image)) + profileID
            let signature = try key.signature(for: message).rawRepresentation
            let _: AvatarUploaded = try await post("/v1/profiles/avatar", [
                "challengeId": challenge.challengeId,
                "imageBase64": image.base64EncodedString(),
                "signature": signature.hex,
            ])
            avatarBytes[handle] = image
            status = "Profile photo updated."
            await loadProfile()
        } catch { status = "Profile photo failed: \(error.localizedDescription)" }
    }

    @discardableResult
    func resetDemo() async -> Bool {
        isBusy = true
        status = "Approve demo reset with Face ID…"
        defer { isBusy = false }
        do {
            guard let profileHex = UserDefaults.standard.string(forKey: "profileID"),
                  let profileID = Data(hexString: profileHex), profileID.count == 16,
                  !handle.isEmpty else { throw AppError.server("Create a profile before resetting this demo") }
            let challenge: DemoResetChallenge = try await post("/v1/dev/reset/challenge", ["profileId": profileHex])
            guard let nonce = Data(hexString: challenge.challenge), nonce.count == 32 else {
                throw AppError.invalidResponse
            }
            let message = Data("pupille:demo-reset:v1".utf8) + nonce + profileID
            let signature = try persistentProfileKey().signature(for: message).rawRepresentation
            let result: DemoResetResult = try await post("/v1/dev/reset", [
                "challengeId": challenge.challengeId, "signature": signature.hex,
            ])
            guard result.reset else { throw AppError.invalidResponse }
            clearLocalIdentity()
            status = "Demo reset. Create a new World verified profile."
            return true
        } catch {
            status = "Reset failed: \(error.localizedDescription)"
            return false
        }
    }

    private func clearLocalIdentity() {
        for key in ["profileHandle", "profileID", "profileKeyReference",
                    "registeredAttestKeyID", "registeredAttestServerKeyID"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        handle = ""
        posts = []
        imageBytes = [:]
        avatarBytes = [:]
        profile = nil
        publicProfiles = [:]
        verifiedPostIDs = []
        verificationChecks = [:]
        reactionCounts = [:]
        myReactions = [:]
        reactingPostIDs = []
        postEnvironments = [:]
        request = nil
        signup = nil
        connectorURL = nil
        worldRequestActive = false
    }

    private func audit(post: FeedPost, image: Data) -> [VerificationCheck] {
        let issuer = Data(hexString: issuerPublicKeyHex)
            .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        let profileBytes = Data(base64Encoded: post.profileCert.certB64)
        let captureBytes = Data(base64Encoded: post.captureCert.certB64)
        let profileSig = Data(base64Encoded: post.profileCert.sigB64)
        let captureSig = Data(base64Encoded: post.captureCert.sigB64)
        let profileSigned = issuer != nil && profileBytes != nil && profileSig != nil
            && issuer!.isValidSignature(profileSig!, for: profileBytes!)
        let captureSigned = issuer != nil && captureBytes != nil && captureSig != nil
            && issuer!.isValidSignature(captureSig!, for: captureBytes!)
        let profile = profileBytes.flatMap { try? JSONDecoder().decode(ProfileCertificate.self, from: $0) }
        let capture = captureBytes.flatMap { try? JSONDecoder().decode(CaptureCertificate.self, from: $0) }
        let imageDigest = Data(SHA256.hash(data: image))
        let noDepth = Data(repeating: 0, count: 32)
        let worldCredential = profile?.credential == "proof_of_human"
            && ["staging", "production"].contains(profile?.environment ?? "")
        let authorMatches = profile?.handle == post.author.handle
            && profile?.profileId == post.author.profileId
            && profile?.publicKey == post.author.publicKey
        let captureMatches = capture?.profileId == profile?.profileId
            && capture?.keyVersion == profile?.keyVersion
            && capture?.depthSha256 == noDepth.hex
        let imageMatches = capture?.imageSha256 == imageDigest.hex
        let captionMatches: Bool
        if let caption = post.caption, !caption.isEmpty {
            captionMatches = capture?.captionSha256 == Data(SHA256.hash(data: Data(caption.utf8))).hex
        } else {
            captionMatches = capture?.captionSha256 == nil && capture != nil
        }
        var computed: Data?
        if let profile, let capture,
           let profileID = Data(hexString: profile.profileId),
           let publicKey = Data(base64Encoded: profile.publicKey),
           let challenge = Data(hexString: capture.challenge),
           let assertionHash = Data(hexString: capture.assertionSha256) {
            computed = Data(SHA256.hash(data: Data("pupille:capture:v1".utf8)
                + imageDigest + noDepth + challenge + assertionHash + profileID + publicKey))
        }
        let commitmentMatches = computed != nil && computed?.hex == capture?.captureCommitment
        var authorSigned = false
        if let computed, let profile,
           let keyBytes = Data(base64Encoded: profile.publicKey),
           let key = try? P256.Signing.PublicKey(x963Representation: keyBytes),
           let signatureBytes = Data(base64Encoded: post.postSignature),
           let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureBytes) {
            authorSigned = key.isValidSignature(signature,
                for: Data("pupille:post-sig:v1".utf8) + computed)
        }
        return [
            VerificationCheck(title: "World Human credential certified at signup", passed: profileSigned && worldCredential),
            VerificationCheck(title: "Profile belongs to this author", passed: authorMatches),
            VerificationCheck(title: "Device capture certified by Pupille", passed: captureSigned && captureMatches),
            VerificationCheck(title: "Exact photo bytes match", passed: imageMatches),
            VerificationCheck(title: "Caption matches", passed: captionMatches),
            VerificationCheck(title: "Capture commitment matches", passed: commitmentMatches),
            VerificationCheck(title: "Author signed this capture", passed: authorSigned),
        ]
    }

    @discardableResult
    func publish(imageData: Data, caption: String) async -> Bool {
        isBusy = true
        status = "Binding your photo to a fresh device challenge…"
        defer { isBusy = false }
        do {
            guard !handle.isEmpty,
                let profileHex = UserDefaults.standard.string(forKey: "profileID"),
                let profileID = Data(hexString: profileHex),
                let attestKeyID = UserDefaults.standard.string(forKey: "registeredAttestKeyID") else {
                throw AppError.server("Create your World verified profile first")
            }
            let key = try persistentProfileKey()
            let challenge: CaptureChallenge = try await post("/v1/captures/challenge", [:],
                headers: ["x-profile-id": profileHex])
            guard let challengeBytes = Data(hexString: challenge.challenge), challengeBytes.count == 32 else {
                throw AppError.invalidResponse
            }
            let imageHash = Data(SHA256.hash(data: imageData))
            let depthHash = Data(repeating: 0, count: 32)
            let clientHash = Data(SHA256.hash(data: Data("pupille:assert:v1".utf8)
                + imageHash + depthHash + challengeBytes))
            let assertion = try await DCAppAttestService.shared.generateAssertion(attestKeyID, clientDataHash: clientHash)
            let assertionHash = Data(SHA256.hash(data: assertion))
            let commitment = Data(SHA256.hash(data: Data("pupille:capture:v1".utf8)
                + imageHash + depthHash + challengeBytes + assertionHash
                + profileID + key.publicKey.x963Representation))
            let postMessage = Data("pupille:post-sig:v1".utf8) + commitment
            let signature = try key.signature(for: postMessage).rawRepresentation
            status = "Checking the capture and signature on the backend…"
            let _: DeviceAccepted = try await post("/v1/captures/\(challenge.challengeId)/device", [
                "imageBase64": imageData.base64EncodedString(),
                "assertionBase64": assertion.base64EncodedString(),
                "postSignature": signature.hex,
                "profilePublicKey": key.publicKey.x963Representation.hex
            ])
            let published: PublishResponse = try await post("/v1/captures/\(challenge.challengeId)/publish", [
                "caption": caption
            ])
            status = "Published photo \(published.postId). The World-backed profile signed this capture."
            await loadFeed()
            await loadProfile()
            return true
        } catch {
            status = "Publish failed: \(error.localizedDescription)"
            return false
        }
    }

    func beginSignup(handle chosenHandle: String) async {
        isBusy = true
        status = "Securing this iPhone…"
        defer { isBusy = false }
        do {
            let attest = try await registeredAttestKey()
            let key = try persistentProfileKey()
            let id = try persistentProfileID()
            let normalized = chosenHandle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let start: StartSignup = try await post("/v1/onboard/start", [
                "profileId": id.hex, "publicKey": key.publicKey.x963Representation.hex,
                "handle": normalized, "attestKeyId": attest.serverID
            ])
            guard ["staging", "production"].contains(start.environment) else { throw AppError.invalidResponse }
            let commitment = Data(SHA256.hash(data: Data("pupille:profile:v1".utf8)
                + id + key.publicKey.x963Representation + Data(normalized.utf8)))
            status = "Approve your profile key with Face ID…"
            let pop = try key.signature(for: Data("pupille:profile-sig:v1".utf8) + commitment).rawRepresentation
            let assertHash = Data(SHA256.hash(data: Data("pupille:profile-assert:v1".utf8) + commitment))
            let assertion = try await DCAppAttestService.shared.generateAssertion(attest.appleID, clientDataHash: assertHash)
            let preflight: DevicePreflight = try await post("/v1/onboard/device", [
                "reservationId": start.reservationId,
                "profilePoP": pop.hex,
                "assertionBase64": assertion.base64EncodedString()
            ])
            guard preflight.deviceVerified else { throw AppError.invalidResponse }
            let context = try RpContext(rpId: rpID, nonce: start.rpContext.nonce,
                createdAt: start.rpContext.createdAt, expiresAt: start.rpContext.expiresAt,
                signature: start.rpContext.sig)
            let config = IDKitRequestConfig(appId: appID, action: "pupille-profile-v1",
                rpContext: context, actionDescription: "Verify one human per Pupille profile",
                allowLegacyProofs: false,
                environment: start.environment == "staging" ? .staging : .production)
            let proofRequest = try IDKit.request(config: config)
                .preset(.proofOfHuman(signal: start.worldSignal))
            signup = start
            worldEnvironment = start.environment
            request = proofRequest
            connectorURL = proofRequest.connectorURL
            worldRequestActive = true
            status = "Open World Simulator and approve the Human proof."
            Task { await awaitWorldProof() }
        } catch {
            status = "Signup failed: \(error.localizedDescription)"
        }
    }

    func awaitWorldProof() async {
        guard let request, let signup else { return }
        let outcome = await request.pollUntilCompletion()
        switch outcome {
        case .failure(let reason):
            status = "World proof failed: \(reason.rawValue)"
        case .success(let result):
            isBusy = true
            status = "World proof received. Verifying on Pupille’s backend…"
            defer { isBusy = false }
            do {
                let resultJSON = try idkitResultToJson(result: result)
                guard let resultObject = try JSONSerialization.jsonObject(with: Data(resultJSON.utf8)) as? [String: Any] else {
                    throw AppError.invalidResponse
                }
                let completed: CompleteSignup = try await post("/v1/onboard/complete", [
                    "reservationId": signup.reservationId, "result": resultObject
                ])
                handle = completed.handle
                UserDefaults.standard.set(handle, forKey: "profileHandle")
                status = "Your @\(handle) profile has a \(worldEnvironment) World Proof of Human."
                worldRequestActive = false
                connectorURL = nil
            } catch {
                status = "Backend rejected signup: \(error.localizedDescription)"
            }
        }
    }

    private func persistentProfileID() throws -> Data {
        if let hex = UserDefaults.standard.string(forKey: "profileID"), let id = Data(hexString: hex), id.count == 16 { return id }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppError.randomFailure }
        let id = Data(bytes)
        UserDefaults.standard.set(id.hex, forKey: "profileID")
        return id
    }

    private func persistentProfileKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let data = UserDefaults.standard.data(forKey: "profileKeyReference") {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
        }
        guard let access = SecAccessControlCreateWithFlags(nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil) else {
            throw AppError.keyFailure
        }
        let context = LAContext()
        context.localizedReason = "Create your Pupille profile key"
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
        UserDefaults.standard.set(key.dataRepresentation, forKey: "profileKeyReference")
        return key
    }

    private func registeredAttestKey() async throws -> (appleID: String, serverID: String) {
        if let appleID = UserDefaults.standard.string(forKey: "registeredAttestKeyID") {
            let serverID = UserDefaults.standard.string(forKey: "registeredAttestServerKeyID")
                ?? appleID.replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            let status: AttestStatus = try await post("/v1/attest/status", ["keyId": serverID])
            if status.registered {
                UserDefaults.standard.set(serverID, forKey: "registeredAttestServerKeyID")
                return (appleID, serverID)
            }
            UserDefaults.standard.removeObject(forKey: "registeredAttestKeyID")
            UserDefaults.standard.removeObject(forKey: "registeredAttestServerKeyID")
        }
        guard DCAppAttestService.shared.isSupported else { throw AppError.attestUnavailable }
        let challenge: AttestChallenge = try await post("/v1/attest/challenge", [:])
        guard let bytes = Data(hexString: challenge.challenge) else { throw AppError.invalidResponse }
        let keyID = try await DCAppAttestService.shared.generateKey()
        let hash = Data(SHA256.hash(data: bytes))
        let attestation = try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: hash)
        let registered: AttestRegistered = try await post("/v1/attest/register", [
            "challengeId": challenge.challengeId, "keyId": keyID,
            "attestationObject": attestation.base64EncodedString()
        ])
        UserDefaults.standard.set(keyID, forKey: "registeredAttestKeyID")
        UserDefaults.standard.set(registered.keyId, forKey: "registeredAttestServerKeyID")
        return (keyID, registered.keyId)
    }

    private func url(_ path: String) throws -> URL {
        guard let base = URL(string: baseURL), let scheme = base.scheme,
            ["http", "https"].contains(scheme), base.host != nil else { throw AppError.invalidURL }
        return base.appending(path: path)
    }

    private func get<T: Decodable>(_ path: String, headers: [String: String] = [:]) async throws -> T {
        var request = URLRequest(url: try url(path))
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decode(data, response)
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any], headers: [String: String] = [:]) async throws -> T {
        var request = URLRequest(url: try url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decode(data, response)
    }

    private func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw AppError.invalidResponse }
        if !(200..<300).contains(http.statusCode) {
            let error = try? JSONDecoder().decode(APIError.self, from: data)
            let message: String
            switch error?.error {
            case "human_already_registered":
                message = "This World test identity already has a Pupille profile. Select another test identity in World Simulator and try again."
            case "handle_taken":
                message = "That handle is already taken. Choose another name."
            default:
                message = error?.error ?? "HTTP \(http.statusCode)"
            }
            throw AppError.server(message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private enum AppError: LocalizedError {
    case invalidURL, invalidResponse, randomFailure, keyFailure, attestUnavailable, server(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid backend URL"
        case .invalidResponse: "Unexpected backend response"
        case .randomFailure: "Could not create profile ID"
        case .keyFailure: "Could not create Secure Enclave key"
        case .attestUnavailable: "App Attest unavailable on this iPhone"
        case .server(let message): message
        }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        for index in stride(from: 0, to: hexString.count, by: 2) {
            let start = hexString.index(hexString.startIndex, offsetBy: index)
            let end = hexString.index(start, offsetBy: 2)
            guard let byte = UInt8(hexString[start..<end], radix: 16) else { return nil }
            bytes.append(byte)
        }
        self = Data(bytes)
    }
}
