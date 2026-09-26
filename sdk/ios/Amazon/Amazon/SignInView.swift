import PupilleKit
import SwiftUI

/// Shown when someone taps "Write a customer review" before this iPhone is verified.
/// This is the whole integration from the store's side: one button that calls PupilleKit.
struct SignInView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let onVerified: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image("PupilleLogo")
                        .resizable().scaledToFit()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(white: 0.88)))
                        .accessibilityLabel("Pupille")
                    VStack(spacing: 8) {
                        Text("Verify you're human to post a photo review").font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text("Photo reviews on this store are protected by Pupille, so every review photo is taken by a real person.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        step("faceid", "Face ID creates a private key on this iPhone. It never leaves the Secure Enclave.")
                        step("iphone.gen3", "Apple App Attest confirms this is the genuine app on a real iPhone.")
                        step("person.badge.shield.checkmark", "World ID proves you're a unique human. No name, email or password is shared.")
                        step("camera.aperture", "Each review photo is then signed on your iPhone the moment you submit it.")
                    }
                    .padding(16)
                    .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 12))
                    if let request = store.pendingWorldProof {
                        worldStep(request)
                    } else {
                        continueButton
                    }
                    Text("Powered by Pupille · World ID").font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }.disabled(store.submitting)
                }
            }
        }
        .interactiveDismissDisabled(store.submitting)
    }

    private var continueButton: some View {
        Button {
            Task {
                if await store.signIn() {
                    dismiss()
                    onVerified()
                }
            }
        } label: {
            HStack(spacing: 10) {
                if store.submitting {
                    ProgressView().tint(.white)
                    Text("Checking this iPhone…")
                } else {
                    Image(systemName: "person.badge.shield.checkmark")
                    Text("Continue with Pupille")
                }
            }
            .font(.headline).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(.black, in: Capsule())
        }
        .disabled(store.submitting)
    }

    private func worldStep(_ request: WorldIDVerification) -> some View {
        VStack(spacing: 12) {
            Button {
                openURL(request.approvalURL)
            } label: {
                Text(request.environment == .staging ? "Open World Simulator" : "Open World App")
                    .font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(.black, in: Capsule())
            }
            ProgressView("Approve the Proof of Human, then come back here.")
                .font(.footnote)
        }
    }

    private func step(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 28)
            Text(text).font(.subheadline)
        }
    }
}
