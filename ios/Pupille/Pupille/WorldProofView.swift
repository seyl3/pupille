import SwiftUI
import PhotosUI
import UIKit
import CryptoKit

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = AppModel()
    @State private var draftHandle = ""
    @State private var backendURL = ""
    @State private var showCamera = false
    @State private var capturedPhoto: Data?
    @State private var caption = ""
    @State private var selectedTab = 0
    @State private var readyToClaimHandle = false
    @State private var exploringAsGuest = false
    @State private var selectedAvatar: PhotosPickerItem?
    @State private var selectedAuditPost: FeedPost?
    @State private var selectedDetailPost: FeedPost?
    @State private var showPublishSuccess = false
    @State private var publishInFlight = false
    @State private var showResetConfirmation = false
    @State private var onboardingVisible = false
    @State private var orbiting = false
    @FocusState private var captionFocused: Bool
    @FocusState private var handleFocused: Bool

    private var handleIsValid: Bool { (3...20).contains(draftHandle.count) }

    var body: some View {
        Group {
            if model.handle.isEmpty && !exploringAsGuest {
                onboarding
            } else {
                mainTabs
            }
        }
        .tint(Color.primary)
        .sheet(isPresented: $model.worldRequestActive) { WorldProofView(model: model) }
        .task { if !model.handle.isEmpty { await model.loadProfile() } }
        .sheet(item: $selectedAuditPost) { post in verificationSheet(for: post) }
        .fullScreenCover(item: $selectedDetailPost) { post in
            PostDetailView(model: model, post: post)
        }
        .confirmationDialog("Reset the demo server?", isPresented: $showResetConfirmation,
                            titleVisibility: .visible) {
            Button("Delete all demo profiles and photos", role: .destructive) {
                Task {
                    if await model.resetDemo() {
                        capturedPhoto = nil
                        caption = ""
                        selectedAvatar = nil
                        draftHandle = ""
                        readyToClaimHandle = false
                        exploringAsGuest = false
                        selectedTab = 0
                    }
                }
            }
        } message: {
            Text("This clears profiles, photos, and reactions on your staging server. Face ID is required.")
        }
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
            GeometryReader { geometry in
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 0) {
                            Spacer(minLength: 24)
                            onboardingHero
                            Spacer(minLength: 32)
                            onboardingAction
                            Spacer(minLength: 28)
                            onboardingServer
                        }
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                        .id("onboarding-top")
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear { scroll.scrollTo("onboarding-top", anchor: .top) }
                }
            }
            .background(PupilleBackdrop())
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { backendURL = model.baseURL }
            .onAppear {
                if reduceMotion {
                    onboardingVisible = true
                } else {
                    withAnimation(.easeOut(duration: 0.6)) { onboardingVisible = true }
                    orbiting = true
                }
            }
        }
    }

    private var onboardingHero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
                    .frame(width: 188, height: 188)
                Circle()
                    .stroke(AngularGradient(
                        colors: [.primary.opacity(0.08), .primary.opacity(0.08),
                                 .primary.opacity(0.48), .primary.opacity(0.08)],
                        center: .center), lineWidth: 2)
                    .frame(width: 188, height: 188)
                    .rotationEffect(.degrees(orbiting ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 11).repeatForever(autoreverses: false),
                               value: orbiting)
                Circle()
                    .stroke(.primary.opacity(0.12), lineWidth: 1)
                    .frame(width: 150, height: 150)
                Image("PupilleIcon")
                    .resizable().scaledToFit()
                    .frame(width: 106, height: 106)
                    .glassEffect(.regular, in: Circle())
            }
            .frame(width: 196, height: 196)
            .accessibilityHidden(true)

            Text("Pupille")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .tracking(-2)
                .minimumScaleFactor(0.8)
            Text("A real human behind every photo.")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .opacity(onboardingVisible ? 1 : 0)
        .offset(y: onboardingVisible ? 0 : 20)
    }

    private var onboardingAction: some View {
        VStack(alignment: .leading, spacing: 18) {
            if readyToClaimHandle {
                Button {
                    handleFocused = false
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) {
                        readyToClaimHandle = false
                    }
                } label: {
                    Label("Back", systemImage: "arrow.left")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityHint("Return to the World ID introduction")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Make it yours.")
                        .font(.title2.weight(.bold))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("YOUR HANDLE")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.4)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("@")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("your_handle", text: $draftHandle)
                            .focused($handleFocused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .submitLabel(.done)
                            .onSubmit { if handleIsValid && !model.isBusy { startSignup() } }
                            .accessibilityLabel("Pupille handle")
                    }
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 58)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 19))
                    .overlay {
                        RoundedRectangle(cornerRadius: 19)
                            .strokeBorder(.primary.opacity(handleFocused ? 0.35 : 0.10), lineWidth: 1)
                    }
                    .animation(.easeOut(duration: 0.2), value: handleFocused)
                    Text(handleIsValid ? "Ready to verify with World ID" : "3–20 letters, numbers, or underscores")
                        .font(.caption)
                        .foregroundStyle(handleIsValid ? Color.green : Color.secondary)
                }
                .onChange(of: draftHandle) { _, value in
                    let cleaned = String(value.lowercased().filter {
                        "abcdefghijklmnopqrstuvwxyz0123456789_".contains($0)
                    }.prefix(20))
                    if draftHandle != cleaned { draftHandle = cleaned }
                }

                Button(action: startSignup) {
                    HStack(spacing: 10) {
                        if model.isBusy { ProgressView().tint(.primary) }
                        Text(model.isBusy ? "Securing this iPhone…" : "Verify and create profile")
                        if !model.isBusy { Image(systemName: "arrow.right") }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.isBusy || !handleIsValid)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your place in the feed")
                        .font(.title2.weight(.bold))
                }
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                        readyToClaimHandle = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { handleFocused = true }
                } label: {
                    HStack {
                        Text("Continue with World ID")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.headline)
                    .frame(minHeight: 54)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
            }

            Button {
                handleFocused = false
                selectedTab = 0
                exploringAsGuest = true
            } label: {
                HStack {
                    Text("Explore as guest")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)

            if !model.status.isEmpty {
                Label(model.status, systemImage: model.status.localizedCaseInsensitiveContains("fail")
                      ? "exclamationmark.circle" : "info.circle")
                    .font(.footnote)
                    .foregroundStyle(model.status.localizedCaseInsensitiveContains("fail") ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .opacity(onboardingVisible ? 1 : 0)
        .offset(y: onboardingVisible ? 0 : 28)
    }

    private var onboardingServer: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Backend URL", text: $backendURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Development backend URL")
                Button("Save server URL") { model.baseURL = backendURL }
                    .buttonStyle(.glass)
            }
            .padding(.top, 12)
        } label: {
            Label("Development server", systemImage: "gearshape")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .opacity(onboardingVisible ? 1 : 0)
    }

    private func startSignup() {
        guard handleIsValid, !model.isBusy else { return }
        handleFocused = false
        Task { await model.beginSignup(handle: draftHandle) }
    }

    private var appBackdrop: some View {
        PupilleBackdrop()
    }

    private var emptyFeed: some View {
        VStack(spacing: 16) {
            Image("PupilleIcon")
                .resizable().scaledToFit().frame(width: 84, height: 84)
                .accessibilityHidden(true)
            Text("Nothing in the feed yet")
                .font(.title2.weight(.bold))
            Text("The first verified photo will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(model.handle.isEmpty ? "Join with World ID" : "Take the first photo") {
                if model.handle.isEmpty {
                    readyToClaimHandle = true
                    exploringAsGuest = false
                } else {
                    selectedTab = 1
                    showCamera = true
                }
            }
            .buttonStyle(.glassProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
        .padding(.top, 40)
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if model.posts.isEmpty { emptyFeed }
                        ForEach(model.posts) { post in feedCard(post) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .background(appBackdrop)
                .navigationTitle("Pupille")
                .navigationDestination(for: String.self) { handle in
                    PublicProfileView(model: model, handle: handle)
                }
                .refreshable { await model.loadFeed() }
                .task { await model.loadFeed() }
            }
            .tabItem { Label("Feed", systemImage: "square.stack") }
            .tag(0)

            NavigationStack {
                ScrollView { captureComposer.padding(20) }
                .background(appBackdrop)
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
                        if model.handle.isEmpty {
                            guestProfileInvitation
                        } else {
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
                        .padding(20)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))

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

                        Text("Captures").font(.title2.bold())
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
                                        Button { selectedDetailPost = post } label: {
                                            Image(uiImage: image).resizable().scaledToFit()
                                                .frame(maxWidth: .infinity)
                                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Open your photo and its proof")
                                    }
                                }
                            }
                        }

                        if !model.status.isEmpty {
                            Text(model.status).font(.footnote).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 12) {
                                TextField("Backend URL", text: $backendURL)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .keyboardType(.URL).textFieldStyle(.roundedBorder)
                                Button("Save server URL") { model.baseURL = backendURL }
                                Button("Reset demo server", role: .destructive) {
                                    showResetConfirmation = true
                                }
                                .foregroundStyle(.red)
                                .disabled(model.isBusy)
                            }.padding(.top, 12)
                        } label: {
                            Label("Development", systemImage: "gearshape")
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                        .padding(18)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
                        }
                    }
                    .padding(20)
                }
                .background(appBackdrop)
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

    private var captureComposer: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("YOUR CAMERA")
                .font(.caption2.weight(.semibold))
                .tracking(1.8)
                .foregroundStyle(.secondary)

            if let data = capturedPhoto, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 30))
                    .accessibilityLabel("Photo ready to publish")
            } else {
                VStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(.primary.opacity(0.12), lineWidth: 1)
                            .frame(width: 156, height: 156)
                        Circle().stroke(.primary.opacity(0.08), lineWidth: 1)
                            .frame(width: 120, height: 120)
                        Image("PupilleIcon").resizable().scaledToFit()
                            .frame(width: 88, height: 88)
                    }
                    .accessibilityHidden(true)
                    Text("Frame your next moment")
                        .font(.headline)
                    Text("Capture with Pupille's camera to make it verifiable.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 340)
                .padding(.horizontal, 20)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(capturedPhoto == nil ? "A moment worth keeping." : "Ready to share?")
                    .font(.title2.weight(.bold))
                Text(capturedPhoto == nil
                     ? "Your camera and profile key will sign the capture."
                     : "Add a caption, then publish your verified capture.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if model.handle.isEmpty {
                Button("Create a profile first") { selectedTab = 2 }
                    .buttonStyle(.glassProminent)
                    .frame(minHeight: 54)
            } else if let data = capturedPhoto {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CAPTION")
                        .font(.caption2.weight(.semibold)).tracking(1.5)
                        .foregroundStyle(.secondary)
                    TextField("Say something about this moment…", text: $caption, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($captionFocused)
                        .font(.body)
                }
                .padding(20)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26))
                .animation(.easeOut(duration: 0.22), value: captionFocused)

                Button {
                    publishCapture(data)
                } label: {
                    HStack(spacing: 10) {
                        if publishInFlight { ProgressView().tint(.primary) }
                        Text(publishInFlight ? "Publishing…" : "Publish verified capture")
                        if !publishInFlight { Image(systemName: "arrow.up.right") }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.isBusy || publishInFlight)
                Button("Take another photo") { showCamera = true }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Button {
                    showCamera = true
                } label: {
                    Label("Open camera", systemImage: "camera")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.glassProminent)
            }

            if !model.status.isEmpty {
                Text(model.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func publishCapture(_ data: Data) {
        guard !publishInFlight else { return }
        publishInFlight = true
        captionFocused = false
        Task {
            if await model.publish(imageData: data, caption: caption) {
                capturedPhoto = nil
                caption = ""
                if reduceMotion {
                    showPublishSuccess = true
                } else {
                    withAnimation(.easeOut(duration: 0.3)) { showPublishSuccess = true }
                }
                try? await Task.sleep(for: .seconds(1.4))
                if reduceMotion {
                    showPublishSuccess = false
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { showPublishSuccess = false }
                }
            }
            publishInFlight = false
        }
    }

    private var guestProfileInvitation: some View {
        VStack(spacing: 18) {
            Image("PupilleIcon")
                .resizable().scaledToFit().frame(width: 92, height: 92)
                .accessibilityHidden(true)
            Text("Make a place for yourself")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text("You can look around now. A World verified profile lets you publish and react.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Continue with World ID") {
                readyToClaimHandle = true
                exploringAsGuest = false
            }
            .buttonStyle(.glassProminent)
            .frame(minHeight: 54)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
        .padding(.top, 48)
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
            NavigationLink(value: post.author.handle) {
                HStack(spacing: 11) {
                    avatar(for: post.author.handle, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("@\(post.author.handle)").font(.headline)
                        Text(model.verificationChecks[post.id] == nil ? "Checking proof"
                             : model.verifiedPostIDs.contains(post.id) ? "Human verified" : "Proof needs review")
                            .font(.caption)
                            .foregroundStyle(model.verifiedPostIDs.contains(post.id) ? Color.green : Color.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View @\(post.author.handle)'s profile")
            ZStack(alignment: .bottomTrailing) {
                if let bytes = model.imageBytes[post.id], let image = UIImage(data: bytes) {
                    Button { selectedDetailPost = post } label: {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open photo by @\(post.author.handle)")
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
                            .contentTransition(.numericText())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(model.handle.isEmpty || model.reactingPostIDs.contains(post.id))
                    .opacity(model.myReactions[post.id] == kind ? 1 : 0.72)
                    .accessibilityLabel("React \(kind), \(model.reactionCounts[post.id]?[kind] ?? 0) reactions")
                }
            }
            if model.handle.isEmpty {
                Text("Create a World verified profile to react")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
    }

    private func verificationSheet(for post: FeedPost) -> some View {
        PostVerificationView(model: model, post: post)
    }
}

private struct PostVerificationView: View {
    @ObservedObject var model: AppModel
    let post: FeedPost
    @Environment(\.dismiss) private var dismiss
    @State private var copiedDetail: String?

    private var checks: [VerificationCheck] {
        model.verificationChecks[post.id] ?? [
            VerificationCheck(title: "Photo could not be checked", passed: false)
        ]
    }

    var body: some View {
        NavigationStack {
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
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Proof details")
                            .font(.headline)
                        ForEach(model.proofDetails(for: post)) { detail in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(detail.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        UIPasteboard.general.string = detail.value
                                        copiedDetail = detail.id
                                        UISelectionFeedbackGenerator().selectionChanged()
                                    } label: {
                                        Label(copiedDetail == detail.id ? "Copied" : "Copy",
                                              systemImage: copiedDetail == detail.id ? "checkmark" : "doc.on.doc")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.plain)
                                }
                                Text(detail.value)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(18)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
                    Text("World Human status was checked by Pupille when the profile was created. This screen verifies Pupille’s signed certificate and the photo bytes; it does not query World again.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 10)
                }
                .padding(22)
            }
            .navigationTitle("Verification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct PublicProfileView: View {
    @ObservedObject var model: AppModel
    let handle: String
    @State private var selectedPost: FeedPost?

    private var authorPosts: [FeedPost] {
        model.posts.filter { $0.author.handle == handle }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    Group {
                        if let data = model.avatarBytes[handle], let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Image("PupilleIcon").resizable().scaledToFill()
                        }
                    }
                    .frame(width: 92, height: 92)
                    .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 8) {
                        Text("@\(handle)").font(.title.bold())
                        if let profile = model.publicProfiles[handle] {
                            Label(model.hasVerifiedHumanCertificate(profile)
                                  ? "World ID · Human" : "Verification unavailable",
                                  systemImage: model.hasVerifiedHumanCertificate(profile)
                                  ? "checkmark.seal.fill" : "xmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(model.hasVerifiedHumanCertificate(profile) ? .green : .red)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))

                HStack(spacing: 8) {
                    Text("\(model.publicProfiles[handle]?.postCount ?? authorPosts.count)")
                        .font(.title2.bold())
                    Text("verified captures").foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))

                Text("Captures").font(.title2.bold())
                if authorPosts.isEmpty {
                    ContentUnavailableView("No captures yet", systemImage: "photo")
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(authorPosts) { post in
                            if let bytes = model.imageBytes[post.id], let image = UIImage(data: bytes) {
                                Button { selectedPost = post } label: {
                                    Image(uiImage: image).resizable().scaledToFit()
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 20))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open capture by @\(handle) and its proof")
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadPublicProfile(handle) }
        .fullScreenCover(item: $selectedPost) { post in
            PostDetailView(model: model, post: post)
        }
    }
}

private struct PostSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct PostShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct PostDetailView: View {
    @ObservedObject var model: AppModel
    let post: FeedPost
    @Environment(\.dismiss) private var dismiss
    @State private var showVerification = false
    @State private var sharePayload: PostSharePayload?
    @State private var showShareError = false
    @State private var shareError = ""

    private var verified: Bool { model.verifiedPostIDs.contains(post.id) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 18) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular, in: Circle())
                    }
                    .accessibilityLabel("Close photo")
                    Spacer()
                    Text("@\(post.author.handle)")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }

                Spacer(minLength: 0)
                ZStack(alignment: .bottomTrailing) {
                    if let bytes = model.imageBytes[post.id], let image = UIImage(data: bytes) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: geometry.size.height * 0.61)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .accessibilityLabel("Photo by @\(post.author.handle)")
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 280)
                    }
                    Button { showVerification = true } label: {
                        Image(systemName: verified ? "checkmark.seal.fill" : "xmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(verified ? Color.green : Color.red)
                            .frame(width: 54, height: 54)
                            .glassEffect(.regular, in: Circle())
                    }
                    .accessibilityLabel("Inspect photo proof")
                    .padding(12)
                }
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 12) {
                    if let caption = post.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { showVerification = true } label: {
                        Label(verified ? "Verified capture" : "Proof needs review",
                              systemImage: verified ? "checkmark.seal.fill" : "xmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(verified ? Color.green : Color.red)
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 12) {
                        Button { prepareShare(includeMessage: true) } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.glassProminent)
                        Button { prepareShare(includeMessage: false) } label: {
                            Label("Export", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.glass)
                    }
                    Text("Export includes the original photo and its signed proof file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showVerification) {
            PostVerificationView(model: model, post: post)
        }
        .sheet(item: $sharePayload) { payload in
            PostShareSheet(items: payload.items)
        }
        .alert("Unable to share", isPresented: $showShareError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError)
        }
    }

    private func prepareShare(includeMessage: Bool) {
        guard let bytes = model.imageBytes[post.id] else {
            shareError = "This photo is still loading. Try again in a moment."
            showShareError = true
            return
        }
        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("pupille-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let imageURL = folder.appendingPathComponent("pupille-\(post.id).jpg")
            let proofURL = folder.appendingPathComponent("pupille-\(post.id)-proof.json")
            try bytes.write(to: imageURL, options: .atomic)
            try model.proofExportData(for: post, image: bytes).write(to: proofURL, options: .atomic)
            var items: [Any] = []
            if includeMessage {
                let digest = Data(SHA256.hash(data: bytes)).hex
                items.append("Hey, verify this Pupille capture by @\(post.author.handle) "
                    + "(profile 0x\(post.author.profileId)). "
                    + "The original photo and signed proof are attached. "
                    + "Photo SHA-256: \(digest). Post ID: \(post.id)")
            }
            items.append(imageURL)
            items.append(proofURL)
            sharePayload = PostSharePayload(items: items)
        } catch {
            shareError = error.localizedDescription
            showShareError = true
        }
    }
}

private struct PupilleBackdrop: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            RadialGradient(colors: [.primary.opacity(0.065), .clear],
                           center: .topLeading, startRadius: 10, endRadius: 400)
            RadialGradient(colors: [.primary.opacity(0.035), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 340)
        }
        .ignoresSafeArea()
    }
}

private struct WorldProofView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 22) {
                        Spacer(minLength: 20)
                        Image("PupilleIcon")
                            .resizable().scaledToFit().frame(width: 104, height: 104)
                            .glassEffect(.regular, in: Circle())
                            .accessibilityHidden(true)
                        Text(model.worldEnvironment == "staging" ? "WORLD ID · STAGING" : "WORLD ID")
                            .font(.caption2.weight(.semibold))
                            .tracking(1.8)
                            .foregroundStyle(.secondary)
                        Text("One human. One profile.")
                            .font(.largeTitle.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(model.worldEnvironment == "staging"
                             ? "Approve a test Human proof in World Simulator. No Orb scan is used in this demo."
                             : "Approve your Orb verified Human proof in World App.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            guard let connector = model.connectorURL else { return }
                            if model.worldEnvironment == "staging" {
                                var destination = URLComponents(string: "https://simulator.worldcoin.org/")
                                destination?.queryItems = [URLQueryItem(name: "connect_url", value: connector.absoluteString)]
                                if let url = destination?.url { openURL(url) }
                            } else {
                                openURL(connector)
                            }
                        } label: {
                            HStack {
                                Text("Connect with World")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.headline)
                            .frame(minHeight: 54)
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(model.connectorURL == nil)
                        if !model.status.isEmpty {
                            Text(model.status)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 20)
                    }
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                    .padding(24)
                }
            }
            .background(PupilleBackdrop())
            .navigationTitle("World ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { model.worldRequestActive = false }
            } }
            .tint(Color.primary)
        }
    }
}
