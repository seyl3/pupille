import PupilleKit
import SwiftUI

enum Palette {
    static let header = Color(red: 0.14, green: 0.18, blue: 0.24)       // #232F3E
    static let headerDark = Color(red: 0.07, green: 0.10, blue: 0.13)   // #131921
    static let deliver = Color(red: 0.22, green: 0.29, blue: 0.36)
    static let link = Color(red: 0.0, green: 0.44, blue: 0.52)          // #007185
    static let star = Color(red: 1.0, green: 0.64, blue: 0.11)          // #FFA41C
    static let yellow = Color(red: 1.0, green: 0.85, blue: 0.08)        // #FFD814
    static let orange = Color(red: 1.0, green: 0.64, blue: 0.11)
    static let badge = Color(red: 0.77, green: 0.33, blue: 0.0)         // #C45500
    static let inStock = Color(red: 0.0, green: 0.46, blue: 0.0)
}

struct Product {
    let id = "sonora-nc700"
    let brand = "Sonora"
    let title = "Sonora NC700 Wireless Noise Cancelling Headphones, 40-Hour Battery, Bluetooth 5.3, Midnight Black"
    let price = "¥19,800"
    let rating = 4.4
    let ratings = 2_317
}

struct ProductView: View {
    @EnvironmentObject private var store: Store
    @State private var writing = false
    @State private var signingIn = false
    @State private var composeAfterSignIn = false
    @State private var proofFor: Review?
    @State private var backendURL = ""
    private let product = Product()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    buyBox
                    Divider().padding(.vertical, 6)
                    reviewsSection
                    Text("Demo app for ETHGlobal Tokyo. Not affiliated with Amazon.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                    DisclosureGroup("Development backend") {
                        HStack {
                            TextField(Store.defaultBackend, text: $backendURL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            Button("Save") {
                                store.backendURL = backendURL
                                Task { await store.loadReviews(for: product.id) }
                            }
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .refreshable { await store.loadReviews(for: product.id) }
        }
        .background(Color(.systemBackground))
        .task {
            backendURL = store.backendURL
            await store.loadReviews(for: product.id)
        }
        .sheet(isPresented: $signingIn, onDismiss: {
            if composeAfterSignIn {
                composeAfterSignIn = false
                writing = true
            }
        }) {
            SignInView { composeAfterSignIn = true }
        }
        .sheet(isPresented: $writing) { ReviewComposer(product: product) }
        .sheet(item: $proofFor) { ProofSheet(review: $0) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.black)
                    Text("Search Amazon").foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "camera.viewfinder").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                Image(systemName: "cart").font(.title2).foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Palette.headerDark)
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                Text("Deliver to Tokyo 150-0002").font(.footnote)
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Palette.deliver)
        }
    }

    // MARK: - Product

    private var buyBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Visit the \(product.brand) Store").font(.subheadline).foregroundStyle(Palette.link)
            HStack(spacing: 6) {
                Text(String(format: "%.1f", product.rating)).font(.subheadline)
                Stars(value: product.rating, size: 13)
                Text("(\(product.ratings.formatted()))").font(.subheadline).foregroundStyle(Palette.link)
            }
            Text(product.title).font(.subheadline)
            Image(systemName: "headphones")
                .resizable().scaledToFit()
                .foregroundStyle(.black.opacity(0.85))
                .padding(48)
                .frame(maxWidth: .infinity).frame(height: 300)
                .background(Color(white: 0.97))
            Text(product.price).font(.system(size: 28, weight: .medium))
            (Text("FREE delivery ") + Text("Tomorrow, October 1").bold()).font(.subheadline)
            Text("In Stock").font(.title3).foregroundStyle(Palette.inStock)
            pill("Add to Cart", Palette.yellow)
            pill("Buy Now", Palette.orange)
        }
    }

    private func pill(_ title: String, _ color: Color) -> some View {
        Text(title)
            .font(.body).foregroundStyle(.black)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(color, in: Capsule())
    }

    // MARK: - Reviews

    private var reviewsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Customer reviews").font(.title3.bold())
            HStack(spacing: 8) {
                Stars(value: product.rating, size: 18)
                Text(String(format: "%.1f out of 5", product.rating)).font(.headline)
            }
            Label("Review photos marked **Verified Human Photo** were taken in the app's camera on a real iPhone by a person verified with World ID.",
                  systemImage: "person.badge.shield.checkmark")
                .font(.footnote)
                .padding(12)
                .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 8))
            Button {
                // The integration point: verify with Pupille only when someone wants to post a photo review.
                if store.reviewer == nil { signingIn = true } else { writing = true }
            } label: {
                Text("Write a customer review")
                    .font(.subheadline).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.7)))
            }
            if let reviewer = store.reviewer {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(Palette.badge)
                    Text("Verified human · \(reviewer)").font(.caption)
                    Spacer()
                    Button("Sign out") { store.signOut() }
                        .font(.caption).foregroundStyle(Palette.link)
                }
            }
            Text("Top reviews from Japan").font(.headline).padding(.top, 8)
            if store.reviews.isEmpty {
                Text("No photo reviews yet. Be the first.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(store.reviews) { review in
                ReviewRow(review: review) { proofFor = review }
                Divider()
            }
        }
    }
}

struct ReviewRow: View {
    let review: Review
    let showProof: () -> Void

    private var verified: Bool { review.post.verification.isVerified }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.gray)
                Text(review.post.post.author.handle).font(.subheadline)
            }
            HStack(spacing: 6) {
                Stars(value: Double(review.content.stars), size: 13)
                Text(review.content.title).font(.subheadline.bold())
            }
            if let date = reviewDate {
                Text("Reviewed in Japan on \(date)").font(.caption).foregroundStyle(.secondary)
            }
            Button(action: showProof) {
                Label(verified ? "Verified Human Photo" : "Photo could not be verified",
                      systemImage: verified ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(verified ? Palette.badge : .red)
            }
            .buttonStyle(.plain)
            Text(review.content.body).font(.subheadline)
            if let data = review.post.imageData, let image = UIImage(data: data) {
                Button(action: showProof) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 110, height: 110).clipped()
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.85)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Review photo. Show proof.")
            }
        }
        .padding(.vertical, 4)
    }

    private var reviewDate: String? {
        guard let raw = review.post.post.createdAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return nil }
        return date.formatted(date: .long, time: .omitted)
    }
}

struct Stars: View {
    let value: Double
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                let fill = value - Double(index)
                Image(systemName: fill >= 0.75 ? "star.fill" : fill >= 0.25 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(Palette.star)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(String(format: "%.1f out of 5 stars", value))
    }
}

struct ProofSheet: View {
    let review: Review

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let data = review.post.imageData, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                            .frame(maxWidth: .infinity)
                    }
                    Text(review.post.verification.isVerified
                         ? "This photo was taken by a verified human in this app's camera, and the rating and text haven't changed since."
                         : "This review failed a check. Don't trust its photo, rating or text.")
                        .font(.subheadline)
                }
                Section("Checked on this iPhone") {
                    ForEach(review.post.verification.checks) { check in
                        Label(check.title, systemImage: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.passed ? .green : .red)
                    }
                }
            }
            .navigationTitle("Photo proof")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
