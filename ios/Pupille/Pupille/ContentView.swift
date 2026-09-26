import SwiftUI

struct DeviceLabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var checks = DeviceChecks()
    @State private var showCamera = false
    @State private var worldResult = "Ready to request a staging Human proof."
    @State private var worldStarted = false
    @State private var worldBusy = false
    @AppStorage("attestProbeURL") private var attestProbeURL = "http://mac.local:8788"
    @AppStorage("worldProbeURL") private var worldProbeURL = "http://mac.local:8791"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PUPILLE / DEVICE LAB")
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Test the iPhone first.")
                            .font(.largeTitle.bold())
                        Text("Test the real camera and device keys, then verify a staging Human proof with World Simulator.")
                            .foregroundStyle(.secondary)
                    }

                    checkCard(
                        title: "Camera",
                        detail: "Take a photo through the app and hash the exact captured bytes.",
                        result: checks.cameraResult,
                        button: "Open camera"
                    ) {
                        showCamera = true
                    }

                    checkCard(
                        title: "Secure Enclave",
                        detail: "Create a temporary hardware key, sign a message with Face ID, and verify the signature.",
                        result: checks.secureEnclaveResult,
                        button: "Test Face ID key"
                    ) {
                        Task { await checks.testSecureEnclave() }
                    }

                    checkCard(
                        title: "App Attest",
                        detail: "Ask Apple to attest a temporary key for this installed app. This can take a few seconds.",
                        result: checks.appAttestResult,
                        button: "Test App Attest"
                    ) {
                        Task { await checks.testAppAttest() }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("World ID / Human")
                            .font(.title2.weight(.semibold))
                        Text("On your Mac, open 127.0.0.1:8790 and present a Human proof in World Simulator. This iPhone reads only World’s verified result.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("Mac World probe URL", text: $worldProbeURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        Button {
                            worldStarted = true
                            Task { await refreshWorldStatus() }
                        } label: {
                            Text("Check World result")
                                .font(.headline)
                                .foregroundStyle(Color(uiColor: .systemBackground))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.primary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(worldBusy)
                        Text(worldResult)
                            .font(.footnote.monospaced())
                            .foregroundStyle(worldResult.hasPrefix("PASS") ? Color.green : Color.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Verify on Mac")
                            .font(.title2.weight(.semibold))
                        Text("Send a fresh Apple attestation to Pupille's local verifier. Mac and iPhone must be on the same Wi-Fi.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("Mac backend URL", text: $attestProbeURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        Button {
                            Task { await checks.testServerAttestation(baseURL: attestProbeURL) }
                        } label: {
                            Text("Verify with backend")
                                .font(.headline)
                                .foregroundStyle(Color(uiColor: .systemBackground))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.primary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(checks.isBusy)
                        Text(checks.serverResult)
                            .font(.footnote.monospaced())
                            .foregroundStyle(checks.serverResult.hasPrefix("PASS") ? Color.green : Color.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                    Text("Staging verifies the demo proof. Profile creation and publishing are the next product steps.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("Pupille")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showCamera) {
                CameraCheckView { result in
                    checks.cameraResult = result
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && worldStarted {
                    Task { await refreshWorldStatus() }
                }
            }
        }
    }

    @MainActor
    private func refreshWorldStatus() async {
        worldBusy = true
        defer { worldBusy = false }
        do {
            let base = try worldBaseURL()
            let (data, response) = try await URLSession.shared.data(from: base.appending(path: "status"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw WorldProbeError.invalidResponse
            }
            let status = try JSONDecoder().decode(WorldProbeStatus.self, from: data)
            worldResult = "\(status.state == "passed" ? "PASS" : status.state == "failed" ? "FAIL" : status.state.uppercased()): \(status.message)"
        } catch {
            worldResult = "FAIL: Could not reach Mac World probe: \(error.localizedDescription)"
        }
    }

    private func worldBaseURL() throws -> URL {
        guard let url = URL(string: worldProbeURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            throw WorldProbeError.invalidURL
        }
        return url
    }

    private func checkCard(
        title: String,
        detail: String,
        result: String,
        button: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
            Button(action: action) {
                Text(button)
                    .font(.headline)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(checks.isBusy)
            Text(result)
                .font(.footnote.monospaced())
                .foregroundStyle(result.hasPrefix("PASS") ? Color.green : Color.secondary)
                .textSelection(.enabled)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct WorldProbeStatus: Decodable {
    let state: String
    let message: String
}

private enum WorldProbeError: LocalizedError {
    case invalidURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter the Mac result URL, for example http://mac.local:8791"
        case .invalidResponse: "The Mac probe returned an unexpected response"
        }
    }
}
