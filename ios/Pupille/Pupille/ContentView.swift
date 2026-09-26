import SwiftUI

struct ContentView: View {
    @StateObject private var checks = DeviceChecks()
    @State private var showCamera = false
    @AppStorage("attestProbeURL") private var attestProbeURL = "http://mac.local:8788"

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
                        Text("These checks use your real camera and device keys. They do not publish a post or create a World ID profile yet.")
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

                    Text("Next: save the attested key, then add World ID and publishing.")
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
        }
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
