import CryptoKit
import DeviceCheck
import Foundation

/// The reactions the backend accepts.
public enum Reaction: String, Codable, Sendable, CaseIterable {
    case heart, nerd, aubergine, japan

    public var emoji: String {
        switch self {
        case .heart: "❤️"
        case .nerd: "🤓"
        case .aubergine: "🍆"
        case .japan: "🇯🇵"
        }
    }
}

public struct ReactionCounts: Codable, Sendable, Equatable {
    public var heart: Int
    public var nerd: Int
    public var aubergine: Int
    public var japan: Int

    public init(heart: Int = 0, nerd: Int = 0, aubergine: Int = 0, japan: Int = 0) {
        self.heart = heart; self.nerd = nerd; self.aubergine = aubergine; self.japan = japan
    }

    public subscript(_ reaction: Reaction) -> Int {
        switch reaction {
        case .heart: heart
        case .nerd: nerd
        case .aubergine: aubergine
        case .japan: japan
        }
    }

    public var total: Int { heart + nerd + aubergine + japan }
}

public struct ReactionResult: Decodable, Sendable {
    public let reactions: ReactionCounts
    public let myReaction: Reaction?
}

extension PupilleClient {
    /// A verified action: reacts to a post with a fresh App Attest assertion over the post,
    /// the reaction and a one-time challenge. The backend rejects reactions from devices that
    /// aren't enrolled with World ID, from modified apps, and replays. One reaction per profile
    /// per post; reacting again replaces it.
    public func react(to postID: String, with reaction: Reaction) async throws -> ReactionResult {
        struct Challenge: Decodable { let challengeId: String; let challenge: String }

        let api = api
        let identity = identity
        guard identity.handle != nil, let profileID = identity.storedProfileID,
              let attestKeyID = identity.storedAttestKeyID else {
            throw PupilleError.notEnrolled
        }
        let challenge: Challenge = try await api.post("/v1/posts/\(postID)/reaction/challenge", [
            "profileId": profileID.hex
        ])
        guard let nonce = Data(hex: challenge.challenge), nonce.count == 32 else {
            throw PupilleError.invalidResponse
        }
        let clientDataHash = Data(SHA256.hash(data: Data("pupille:reaction:v1".utf8)
            + Data(postID.utf8) + Data(reaction.rawValue.utf8) + nonce))
        let assertion = try await DCAppAttestService.shared.generateAssertion(attestKeyID, clientDataHash: clientDataHash)
        return try await api.post("/v1/posts/\(postID)/reaction", [
            "challengeId": challenge.challengeId,
            "reaction": reaction.rawValue,
            "assertionBase64": assertion.base64EncodedString()
        ])
    }
}
