import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var draftHandle = ""
    @State private var backendURL = ""
    @State private var showCamera = false
    @State private var capturedPhoto: Data?
    @State private var caption = ""
    @State private var selectedTab = 0
    @State private var readyToClaimHandle = false

    var body: some View {
        Group {
            if model.handle.isEmpty {
                onboarding
            } else {
                mainTabs
            }
        }
        .sheet(isPresented: $model.worldRequestActive) { WorldProofView(model: model) }
    }

    private var onboarding: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Spacer()
                Image("PupilleLogo")
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
                    LazyVStack(spacing: 18) {
                        if model.posts.isEmpty {
                            VStack(spacing: 12) {
                                Image("PupilleLogo")
                                    .resizable().scaledToFit().frame(width: 104, height: 104)
                                Text("No photos yet").font(.title2.bold())
                                Text("Human verified captures will appear here.")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 80)
                        }
                        ForEach(model.posts) { post in
                            VStack(alignment: .leading, spacing: 10) {
                                Group {
                                    if let bytes = model.imageBytes[post.id], let image = UIImage(data: bytes) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else { Rectangle().fill(.gray.opacity(0.15)) }
                                }
                                .frame(height: 300)
                                .clipped()
                                Text("@\(post.author.handle)").font(.headline)
                                if let caption = post.caption { Text(caption) }
                                Label(model.verifiedPostIDs.contains(post.id)
                                    ? "Verified bytes and author · \(model.postEnvironments[post.id] ?? "unknown") Human proof at signup"
                                    : "Unverified capture", systemImage: model.verifiedPostIDs.contains(post.id)
                                    ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(model.verifiedPostIDs.contains(post.id) ? .green : .orange)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 12)
                        }
                    }
                    .padding()
                }
                .navigationTitle("Pupille")
                .refreshable { await model.loadFeed() }
                .task { await model.loadFeed() }
            }
            .tabItem { Label("Feed", systemImage: "square.stack") }
            .tag(0)

            NavigationStack {
                ScrollView { VStack(spacing: 16) {
                    if let data = capturedPhoto, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxHeight: 420).clipShape(RoundedRectangle(cornerRadius: 18))
                    } else {
                        Image("PupilleLogo")
                            .resizable().scaledToFit().frame(width: 92, height: 92)
                    }
                    Text("Capture through Pupille").font(.title2.bold())
                    Text("Your photo will be bound to the device and your World-backed profile key.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if model.handle.isEmpty {
                        Button("Create a profile first") { selectedTab = 2 }
                            .font(.headline)
                    } else {
                        Text("Signed in as @\(model.handle)").font(.headline)
                        Button("Take photo") { showCamera = true }
                            .buttonStyle(.borderedProminent)
                        if let data = capturedPhoto {
                            TextField("Caption", text: $caption)
                                .textFieldStyle(.roundedBorder)
                            Button("Publish verified capture") {
                                Task { await model.publish(imageData: data, caption: caption) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isBusy)
                        }
                    }
                    if !model.status.isEmpty { Text(model.status).font(.footnote).textSelection(.enabled) }
                }
                .padding(24)
                }
                .navigationTitle("Capture")
                .sheet(isPresented: $showCamera) {
                    CameraCheckView(onResult: { _ in }, onPhoto: { capturedPhoto = $0 })
                }
            }
            .tabItem { Label("Capture", systemImage: "camera") }
            .tag(1)

            NavigationStack {
                Form {
                    if model.handle.isEmpty {
                        Section("Claim a handle") {
                            TextField("your_handle", text: $draftHandle)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Verify with World ID") {
                                Task { await model.beginSignup(handle: draftHandle) }
                            }
                            .disabled(model.isBusy || draftHandle.count < 3)
                        }
                    } else {
                        Section("Profile") {
                            Text("@\(model.handle)").font(.title2.bold())
                            Label("Proof of Human verified at signup", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    Section("Development backend") {
                        TextField("http://mac.local:8787", text: $backendURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit { model.baseURL = backendURL }
                        Button("Save server URL") { model.baseURL = backendURL }
                    }
                    if !model.status.isEmpty {
                        Section("Status") { Text(model.status).textSelection(.enabled) }
                    }
                    Section { NavigationLink("Device checks") { DeviceLabView() } }
                }
                .navigationTitle("Profile")
                .onAppear { backendURL = model.baseURL }
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(2)
        }
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
