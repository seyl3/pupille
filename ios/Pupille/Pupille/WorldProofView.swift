import SwiftUI
import PhotosUI
import UIKit

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var draftHandle = ""
    @State private var backendURL = ""
    @State private var showCamera = false
    @State private var capturedPhoto: Data?
    @State private var caption = ""
    @State private var selectedTab = 0
    @State private var readyToClaimHandle = false
    @State private var selectedAvatar: PhotosPickerItem?
    @State private var selectedAuditPost: FeedPost?
    @State private var showPublishSuccess = false
    @State private var publishInFlight = false
    @FocusState private var captionFocused: Bool

    var body: some View {
        Group {
            if model.handle.isEmpty {
                onboarding
            } else {
                mainTabs
            }
        }
        .sheet(isPresented: $model.worldRequestActive) { WorldProofView(model: model) }
        .sheet(item: $selectedAuditPost) { post in verificationSheet(for: post) }
        .overlay {
            if showPublishSuccess {
                ZStack {
                    Color.black.opacity(0.32).ignoresSafeArea()
                    VStack(spacing: 18) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 92, height: 92)
                            .background(.green, in: Circle())
                            .symbolEffect(.bounce, value: showPublishSuccess)
                        Text("Published").font(.title.bold())
                        Text("Your moment is in the feed.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
                }
                .onAppear { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            }
        }
    }

    private var onboarding: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Spacer()
                Image("PupilleIcon")
                    .resizable().scaledToFit().frame(width: 110, height: 110)
                Text("Pupille").font(.system(size: 52, weight: .bold))
                Text("Photos with a human behind the camera.")
                    .font(.title2).foregroundStyle(.secondary)
                if readyToClaimHandle {
                    Text("Choose the name your World proof will bind to this iPhone.")
                        .foregroundStyle(.secondary)
                    TextField("your_handle", text: $draftHandle)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("Verify and create profile") {
                        Task { await model.beginSignup(handle: draftHandle) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || draftHandle.count < 3)
                } else {
                    Button("Continue with World ID") { readyToClaimHandle = true }
                        .buttonStyle(.borderedProminent)
                }
                if !model.status.isEmpty { Text(model.status).font(.footnote).textSelection(.enabled) }
                Spacer()
                DisclosureGroup("Development server") {
                    TextField("Backend URL", text: $backendURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Save server URL") { model.baseURL = backendURL }
                }
                NavigationLink("Device checks") { DeviceLabView() }
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(28)
            .onAppear { backendURL = model.baseURL }
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScrollView {
                    LazyVStack(spacing: 24) {
                        if model.posts.isEmpty {
                            VStack(spacing: 12) {
                                Image("PupilleIcon")
                                    .resizable().scaledToFit().frame(width: 104, height: 104)
                                Text("No photos yet").font(.title2.bold())
                                Text("Human verified captures will appear here.")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 80)
                        }
                        ForEach(model.posts) { post in feedCard(post) }
                    }
                    .padding()
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("Pupille")
                .refreshable { await model.loadFeed() }
                .task { await model.loadFeed() }
            }
            .tabItem { Label("Feed", systemImage: "square.stack") }
            .tag(0)

            NavigationStack {
                ScrollView { VStack(spacing: 20) {
                    if let data = capturedPhoto, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity).frame(maxHeight: 520)
                            .clipShape(RoundedRectangle(cornerRadius: 28))
                    } else {
                        Image("PupilleIcon")
                            .resizable().scaledToFit().frame(width: 108, height: 108)
                            .frame(maxWidth: .infinity).frame(height: 280)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
                    }
                    Text(capturedPhoto == nil ? "A moment worth keeping." : "Ready to share?")
                        .font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Captured in Pupille. Bound to your verified profile.")
                        .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.secondary)
                    if model.handle.isEmpty {
                        Button("Create a profile first") { selectedTab = 2 }
                            .font(.headline)
                    } else {
                        Button("Take photo") { showCamera = true }
                            .buttonStyle(.glassProminent).controlSize(.large)
                            .frame(maxWidth: .infinity)
                        if let data = capturedPhoto {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("CAPTION")
                                    .font(.caption.weight(.semibold)).tracking(1.5)
                                    .foregroundStyle(.secondary)
                                TextField("Say something about this moment…", text: $caption, axis: .vertical)
                                    .lineLimit(2...5)
                                    .focused($captionFocused)
                                    .font(.body)
                            }
                            .padding(18)
                            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26))
                            .animation(.easeOut(duration: 0.25), value: captionFocused)
                            Button("Publish verified capture") {
                                guard !publishInFlight else { return }
                                publishInFlight = true
                                captionFocused = false
                                Task {
                                    if await model.publish(imageData: data, caption: caption) {
                                        capturedPhoto = nil
                                        caption = ""
                                        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                                            showPublishSuccess = true
                                        }
                                        try? await Task.sleep(for: .seconds(1.4))
                                        withAnimation(.easeOut(duration: 0.25)) { showPublishSuccess = false }
                                    }
                                    publishInFlight = false
                                }
                            }
                            .buttonStyle(.glassProminent).controlSize(.large)
                            .disabled(model.isBusy || publishInFlight)
                        }
                    }
                    if !model.status.isEmpty { Text(model.status).font(.footnote).textSelection(.enabled) }
                }
                .padding(20)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("Capture")
                .sheet(isPresented: $showCamera) {
                    CameraCheckView(onResult: { _ in }, onPhoto: { capturedPhoto = $0 })
                }
            }
            .tabItem { Label("Capture", systemImage: "camera") }
            .tag(1)

            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        HStack(alignment: .center, spacing: 18) {
                            let profileHandle = model.handle
                            PhotosPicker(selection: $selectedAvatar, matching: .images) {
                                ZStack(alignment: .bottomTrailing) {
                                    avatar(for: profileHandle, size: 94)
                                    Image(systemName: "plus")
                                        .font(.caption.bold()).frame(width: 28, height: 28)
                                        .foregroundStyle(.primary)
                                        .glassEffect(.regular, in: Circle())
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Change profile photo")
                            VStack(alignment: .leading, spacing: 7) {
                                Text("@\(model.handle)").font(.title.bold())
                                    .minimumScaleFactor(0.7).lineLimit(1)
                                Label("World ID · Human", systemImage: "checkmark.seal.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                            Spacer(minLength: 0)
                        }

                        HStack(spacing: 30) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(model.profile?.postCount ?? model.posts.filter { $0.author.handle == model.handle }.count)")
                                    .font(.title2.bold())
                                Text("posts").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Rectangle().fill(.secondary.opacity(0.2)).frame(width: 1, height: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("1").font(.title2.bold())
                                Text("human proof").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(22)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))

                        Text("Your captures").font(.title2.bold())
                        let ownPosts = model.posts.filter { $0.author.handle == model.handle }
                        if ownPosts.isEmpty {
                            VStack(spacing: 12) {
                                Image("PupilleIcon").resizable().scaledToFit()
                                    .frame(width: 80, height: 80)
                                Text("Your first photo starts here.")
                                    .font(.headline).foregroundStyle(.secondary)
                                Button("Open camera") { selectedTab = 1; showCamera = true }
                                    .buttonStyle(.glassProminent)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 44)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                ForEach(ownPosts) { post in
                                    if let bytes = model.imageBytes[post.id], let image = UIImage(data: bytes) {
                                        Image(uiImage: image).resizable().scaledToFit()
                                            .frame(maxWidth: .infinity)
                                            .clipShape(RoundedRectangle(cornerRadius: 20))
                                            .accessibilityLabel("Photo posted by you")
                                    }
                                }
                            }
                        }

                        if !model.status.isEmpty {
                            Text(model.status).font(.footnote).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        DisclosureGroup("Development") {
                            VStack(alignment: .leading, spacing: 12) {
                                TextField("Backend URL", text: $backendURL)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .keyboardType(.URL).textFieldStyle(.roundedBorder)
                                Button("Save server URL") { model.baseURL = backendURL }
                                NavigationLink("Device checks") { DeviceLabView() }
                            }.padding(.top, 10)
                        }.font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(20)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("Profile")
                .onAppear { backendURL = model.baseURL }
                .task { await model.loadProfile(); await model.loadFeed() }
                .onChange(of: selectedAvatar) { _, item in
                    Task {
                        guard let bytes = try? await item?.loadTransferable(type: Data.self),
                              let image = UIImage(data: bytes) else { return }
                        let edge: CGFloat = 640
                        let ratio = min(1, edge / max(image.size.width, image.size.height))
                        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                        let resized = UIGraphicsImageRenderer(size: size).image { _ in
                            image.draw(in: CGRect(origin: .zero, size: size))
                        }
                        if let jpeg = resized.jpegData(compressionQuality: 0.8) {
                            await model.uploadAvatar(jpeg)
                        }
                    }
                }
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(2)
        }
    }

    private func avatar(for handle: String, size: CGFloat) -> some View {
        Group {
            if let data = model.avatarBytes[handle], let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image("PupilleIcon").resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 2))
    }

    private func feedCard(_ post: FeedPost) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                avatar(for: post.author.handle, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(post.author.handle)").font(.headline)
                    Text("Human verified").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ZStack(alignment: .bottomTrailing) {
                if let bytes = model.imageBytes[post.id], let image = UIImage(data: bytes) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                } else {
                    RoundedRectangle(cornerRadius: 22).fill(.secondary.opacity(0.1))
                        .frame(height: 180)
                }
                Button { selectedAuditPost = post } label: {
                    Image(systemName: model.verifiedPostIDs.contains(post.id)
                        ? "checkmark.seal.fill" : "xmark.circle.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(model.verifiedPostIDs.contains(post.id) ? .green : .red)
                        .frame(width: 54, height: 54)
                        .glassEffect(.regular, in: Circle())
                }
                .accessibilityLabel("View photo verification details")
                .padding(12)
            }
            if let caption = post.caption, !caption.isEmpty {
                Text(caption).font(.body)
            }
            HStack(spacing: 7) {
                ForEach([("nerd", "🤓"), ("heart", "❤️"), ("aubergine", "🍆"), ("japan", "🇯🇵")], id: \.0) { kind, emoji in
                    Button {
                        Task { await model.react(to: post.id, kind: kind) }
                    } label: {
                        Text("\(emoji) \(model.reactionCounts[post.id]?[kind] ?? 0)")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(model.reactingPostIDs.contains(post.id))
                    .opacity(model.myReactions[post.id] == kind ? 1 : 0.72)
                    .accessibilityLabel("React \(kind), \(model.reactionCounts[post.id]?[kind] ?? 0) reactions")
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
    }

    private func verificationSheet(for post: FeedPost) -> some View {
        let checks = model.verificationChecks[post.id] ?? [
            VerificationCheck(title: "Photo could not be checked", passed: false)
        ]
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: model.verifiedPostIDs.contains(post.id)
                            ? "checkmark.seal.fill" : "xmark.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(model.verifiedPostIDs.contains(post.id) ? .green : .red)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.verifiedPostIDs.contains(post.id) ? "Verified capture" : "Verification failed")
                                .font(.title2.bold())
                            Text("@\(post.author.handle)").foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))

                    ForEach(checks) { check in
                        Label(check.title, systemImage: check.passed
                              ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(check.passed ? .green : .red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    Text("World Human status was checked by Pupille when the profile was created. This screen verifies Pupille’s signed certificate and the photo bytes; it does not query World again.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 10)
                }
                .padding(22)
            }
            .navigationTitle("Verification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { selectedAuditPost = nil }
            } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct WorldProofView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Verify your humanity")
                    .font(.largeTitle.bold())
                Text(model.worldEnvironment == "staging"
                    ? "For this staging demo, World Simulator provides a test Human identity. Production uses an Orb verified World ID."
                    : "Approve this Proof of Human in World App with your Orb verified account.")
                    .foregroundStyle(.secondary)
                Button(model.worldEnvironment == "staging" ? "Open World Simulator" : "Open World App") {
                    guard let connector = model.connectorURL else { return }
                    if model.worldEnvironment == "staging" {
                        var destination = URLComponents(string: "https://simulator.worldcoin.org/")
                        destination?.queryItems = [URLQueryItem(name: "connect_url", value: connector.absoluteString)]
                        if let url = destination?.url { openURL(url) }
                    } else {
                        openURL(connector)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.connectorURL == nil)
                Text(model.status).font(.footnote).textSelection(.enabled)
                Spacer()
            }
            .padding(24)
            .navigationTitle("World ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { model.worldRequestActive = false }
            } }
        }
    }
}
