import PupilleKit
import SwiftUI

struct ReviewComposer: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let product: Product

    @State private var stars = 0
    @State private var headline = ""
    @State private var text = ""
    @State private var photo: CapturedPhoto?
    @State private var showCamera = false

    private var ready: Bool { stars > 0 && !headline.isEmpty && !text.isEmpty && photo != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "headphones").font(.title).frame(width: 44)
                        Text(product.title).font(.footnote).lineLimit(2)
                    }
                    if let reviewer = store.reviewer {
                        Label("Posting as \(reviewer) · verified human", systemImage: "checkmark.shield.fill")
                            .font(.footnote).foregroundStyle(Palette.badge)
                    }
                }
                Section("Overall rating") {
                    HStack {
                        ForEach(1...5, id: \.self) { value in
                            Button { stars = value } label: {
                                Image(systemName: value <= stars ? "star.fill" : "star")
                                    .font(.title).foregroundStyle(Palette.star)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(value) stars")
                        }
                    }
                }
                Section("Add a headline") {
                    TextField("What's most important to know?", text: $headline)
                }
                Section("Add a written review") {
                    TextField("What did you like or dislike?", text: $text, axis: .vertical).lineLimit(3...8)
                }
                Section {
                    if let photo, let image = UIImage(data: photo.imageData) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                            .frame(maxWidth: .infinity)
                        Button("Retake photo") { showCamera = true }
                    } else {
                        Button { showCamera = true } label: {
                            Label("Take a photo", systemImage: "camera")
                        }
                    }
                } header: {
                    Text("Add a photo")
                } footer: {
                    Text("Photos come only from the in-app camera. When you submit, Face ID signs the exact photo on this iPhone.")
                }
            }
            .navigationTitle("Create review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(store.submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.submitting {
                        ProgressView()
                    } else {
                        Button("Submit") { submit() }.disabled(!ready).fontWeight(.semibold)
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                PupilleCameraView(onCapture: { photo = $0 }, onFailure: { store.message = $0.localizedDescription })
            }
        }
        .interactiveDismissDisabled(store.submitting)
    }

    private func submit() {
        guard let photo else { return }
        let review = ReviewContent(product: product.id, stars: stars, title: headline, body: text)
        Task {
            if await store.submit(review, photo: photo) { dismiss() }
        }
    }
}
