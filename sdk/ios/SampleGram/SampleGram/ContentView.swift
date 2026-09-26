import PupilleKit
import SwiftUI

/// SampleGram: a minimal photo app built only on PupilleKit's public API.
@MainActor
final class SampleGram: ObservableObject {
    @Published var handle: String?
    @Published var posts: [VerifiedPost] = []
    @Published var pendingWorldProof: WorldIDVerification?
    @Published var status = ""
    @Published var busy = false

    let pupille: PupilleClient

    init() {
        let backend = UserDefaults.standard.string(forKey: "backendURL") ?? "http://mac.local:8789"
        pupille = PupilleClient(configuration: PupilleConfiguration(
            backendURL: URL(string: backend) ?? URL(string: "http://mac.local:8789")!,
            worldAppID: "app_28d96ebb9f1fea8424710dd817901dcd",
            worldRPID: "rp_53e28a7c639fa2a7",
            issuerPublicKey: Data(hexString: "46699f0e689eb90902f3a7f3850b7dde146b77389161e3a1caa8d8062da92fb8")!,
            trustedAppIDs: ["4397GAXGZ4.app.pupille.dev", "4397GAXGZ4.app.pupille.sample"]
        ))
        handle = pupille.enrolledHandle
    }

    var backendURL: String {
        get { pupille.configuration.backendURL.absoluteString }
        set {
            guard let url = URL(string: newValue) else { return }
            pupille.configuration.backendURL = url
            UserDefaults.standard.set(newValue, forKey: "backendURL")
        }
    }

    func enroll(as name: String) async {
        await run("Checking this iPhone…") {
            let request = try await pupille.beginEnrollment(handle: name)
            pendingWorldProof = request
            status = "Approve the Proof of Human in World."
            let enrollment = try await request.result()
            pendingWorldProof = nil
            handle = enrollment.handle
            status = "Enrolled as @\(enrollment.handle) (\(enrollment.environment.rawValue) Human)."
        }
    }

    func publish(_ photo: CapturedPhoto, caption: String) async {
        await run("Signing and publishing…") {
            _ = try await pupille.publish(photo, caption: caption)
            status = "Published."
            posts = try await pupille.loadFeed()
        }
    }

    func refresh() async {
        await run(nil) { posts = try await pupille.loadFeed() }
    }

    private func run(_ message: String?, _ work: () async throws -> Void) async {
        busy = true
        if let message { status = message }
        defer { busy = false }
        do { try await work() } catch {
            pendingWorldProof = nil
            status = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @StateObject private var app = SampleGram()
    @State private var name = ""
    @State private var showCamera = false
    @State private var photo: CapturedPhoto?
    @State private var caption = ""
    @State private var backendURL = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                if let handle = app.handle {
                    Section("Signed in as @\(handle)") {
                        Button("Take a verified photo") { showCamera = true }
                        if let photo, let image = UIImage(data: photo.imageData) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            TextField("Caption", text: $caption)
                            Button("Publish") {
                                Task {
                                    await app.publish(photo, caption: caption)
                                    self.photo = nil
                                    caption = ""
                                }
                            }
                            .disabled(app.busy)
                        }
                    }
                } else {
                    Section("Join with World ID") {
                        TextField("handle", text: $name)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Verify I'm human") { Task { await app.enroll(as: name) } }
                            .disabled(app.busy || name.count < 3)
                    }
                }
                if !app.status.isEmpty {
                    Section { Text(app.status).font(.footnote) }
                }
                Section("Feed") {
                    if app.posts.isEmpty { Text("No photos yet").foregroundStyle(.secondary) }
                    ForEach(app.posts) { PostRow(post: $0) }
                }
                Section("Development backend") {
                    TextField("http://mac.local:8789", text: $backendURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onSubmit { app.backendURL = backendURL }
                    Button("Save") { app.backendURL = backendURL }
                }
            }
            .navigationTitle("SampleGram")
            .refreshable { await app.refresh() }
            .task { backendURL = app.backendURL; await app.refresh() }
            .fullScreenCover(isPresented: $showCamera) {
                PupilleCameraView(onCapture: { photo = $0 }, onFailure: { app.status = $0.localizedDescription })
            }
            .sheet(item: $app.pendingWorldProof) { request in
                VStack(spacing: 16) {
                    Text("Prove you're human").font(.title2.bold())
                    Text(request.environment == .staging ? "Staging uses World Simulator." : "Approve in World App.")
                        .foregroundStyle(.secondary)
                    Button(request.environment == .staging ? "Open World Simulator" : "Open World App") {
                        openURL(request.approvalURL)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(32)
                .presentationDetents([.medium])
            }
        }
    }
}

struct PostRow: View {
    let post: VerifiedPost
    @State private var showChecks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data = post.imageData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Text("@\(post.post.author.handle)").font(.headline)
                Spacer()
                Button {
                    showChecks = true
                } label: {
                    Label(post.verification.isVerified ? "Verified" : "Unverified",
                          systemImage: post.verification.isVerified ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(post.verification.isVerified ? .green : .red)
                }
                .buttonStyle(.borderless)
                if let file = shareableFile() {
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.borderless)
                }
            }
            if let caption = post.post.caption, !caption.isEmpty { Text(caption) }
            if let app = post.verification.appID {
                Text(app).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showChecks) {
            List(post.verification.checks) { check in
                Label(check.title, systemImage: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(check.passed ? .green : .red)
            }
            .presentationDetents([.medium])
        }
    }

    /// Shares a file, not an image, so the exact bytes and the embedded proof survive.
    private func shareableFile() -> URL? {
        guard let data = try? post.shareableJPEG() else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "pupille-\(post.id).jpg")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
