import Foundation
import PupilleKit

/// A review is a Pupille post whose caption is this JSON. The capture certificate hashes
/// the caption, so the rating and text are covered by the same proof as the photo.
struct ReviewContent: Codable {
    let product: String
    let stars: Int
    let title: String
    let body: String
}

struct Review: Identifiable {
    let post: VerifiedPost
    let content: ReviewContent
    var id: String { post.id }
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var reviews: [Review] = []
    /// The reviewer's pseudonymous handle once this iPhone has signed in with Pupille.
    @Published private(set) var reviewer: String?
    @Published var pendingWorldProof: WorldIDVerification?
    @Published var message: String?
    @Published private(set) var submitting = false

    let pupille: PupilleClient
    static let defaultBackend = "http://mac.local:8789"

    init() {
        let backend = UserDefaults.standard.string(forKey: "backendURL") ?? Self.defaultBackend
        pupille = PupilleClient(configuration: PupilleConfiguration(
            backendURL: URL(string: backend) ?? URL(string: Self.defaultBackend)!,
            worldAppID: "app_28d96ebb9f1fea8424710dd817901dcd",
            worldRPID: "rp_53e28a7c639fa2a7",
            worldActionDescription: "Prove a real person took your review photos",
            issuerPublicKey: Data(hex: "46699f0e689eb90902f3a7f3850b7dde146b77389161e3a1caa8d8062da92fb8")!,
            trustedAppIDs: ["4397GAXGZ4.app.pupille.sample"]
        ))
        reviewer = pupille.enrolledHandle
    }

    var backendURL: String {
        get { pupille.configuration.backendURL.absoluteString }
        set {
            guard let url = URL(string: newValue), url.host != nil else { return }
            pupille.configuration.backendURL = url
            UserDefaults.standard.set(newValue, forKey: "backendURL")
        }
    }

    func loadReviews(for product: String) async {
        do {
            reviews = try await pupille.loadFeed().compactMap { post in
                guard let data = post.post.caption?.data(using: .utf8),
                      let content = try? JSONDecoder().decode(ReviewContent.self, from: data),
                      content.product == product else { return nil }
                return Review(post: post, content: content)
            }
        } catch {
            message = "Couldn't load reviews: \(error.localizedDescription)"
        }
    }

    /// "Continue with Pupille": one Face ID prompt to create this iPhone's signing key and
    /// check App Attest, then one World ID Proof of Human. No store account or password.
    func signIn() async -> Bool {
        submitting = true
        defer { submitting = false }
        do {
            let request = try await pupille.beginEnrollment(handle: Self.anonymousHandle())
            pendingWorldProof = request
            let enrollment = try await request.result()
            pendingWorldProof = nil
            reviewer = enrollment.handle
            return true
        } catch {
            pendingWorldProof = nil
            message = error.localizedDescription
            return false
        }
    }

    /// Face ID signs the exact photo, and the backend checks a fresh App Attest assertion.
    func submit(_ content: ReviewContent, photo: CapturedPhoto) async -> Bool {
        submitting = true
        defer { submitting = false }
        do {
            _ = try await pupille.publish(photo, caption: Self.caption(for: content))
            await loadReviews(for: content.product)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func signOut() {
        pupille.signOut()
        reviewer = nil
    }

    /// The backend keeps 500 characters of a caption, so shorten the body until the JSON fits.
    private static func caption(for content: ReviewContent) -> String {
        var body = content.body
        while true {
            let review = ReviewContent(product: content.product, stars: content.stars,
                                       title: String(content.title.prefix(80)), body: body)
            let json = String(decoding: try! JSONEncoder().encode(review), as: UTF8.self)
            if json.utf16.count <= 480 || body.isEmpty { return json }
            body = String(body.dropLast(20))
        }
    }

    private static func anonymousHandle() -> String {
        "shopper_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
