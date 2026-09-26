import CryptoKit
import DeviceCheck
import Foundation
import LocalAuthentication
import Security

@MainActor
final class DeviceChecks: ObservableObject {
    @Published var isBusy = false
    @Published var cameraResult = "Not tested"
    @Published var secureEnclaveResult = "Not tested"
    @Published var appAttestResult = "Not tested"
    @Published var serverResult = "Not tested"

    private struct ChallengeResponse: Decodable {
        let challengeId: String
        let challenge: String
    }

    private struct VerifyResponse: Decodable {
        let verified: Bool?
        let error: String?
    }

    private struct VerifyRequest: Encodable {
        let challengeId: String
        let keyId: String
        let attestationObject: String
    }

    func testSecureEnclave() async {
        isBusy = true
        secureEnclaveResult = "Creating temporary key…"
        defer { isBusy = false }

        do {
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage, .biometryCurrentSet],
                nil
            ) else {
                secureEnclaveResult = "FAIL: Could not create Face ID access control"
                return
            }
            let context = LAContext()
            context.localizedReason = "Test Pupille's profile signing key"
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                accessControl: access,
                authenticationContext: context
            )
            let message = Data("pupille:device-check:v1".utf8)
            let signature = try key.signature(for: message)
            guard key.publicKey.isValidSignature(signature, for: message) else {
                secureEnclaveResult = "FAIL: Signature did not verify"
                return
            }
            let fingerprint = SHA256.hash(data: key.publicKey.x963Representation)
            secureEnclaveResult = "PASS: Face ID key signed and verified. Key fingerprint: \(fingerprint.prefix(6).map { String(format: "%02x", $0) }.joined())"
        } catch {
            secureEnclaveResult = "FAIL: \(error.localizedDescription)"
        }
    }

    func testAppAttest() async {
        isBusy = true
        appAttestResult = "Contacting Apple…"
        defer { isBusy = false }

        let service = DCAppAttestService.shared
        guard service.isSupported else {
            appAttestResult = "FAIL: App Attest is unsupported on this device or signing profile"
            return
        }

        do {
            let keyID = try await service.generateKey()
            var challenge = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, challenge.count, &challenge) == errSecSuccess else {
                appAttestResult = "FAIL: Could not generate challenge"
                return
            }
            let clientDataHash = Data(SHA256.hash(data: Data(challenge)))
            let attestation = try await service.attestKey(keyID, clientDataHash: clientDataHash)
            appAttestResult = "PASS: Apple returned \(attestation.count) attestation bytes. Server verification is the next step."
        } catch {
            appAttestResult = "FAIL: \(error.localizedDescription)"
        }
    }

    func testServerAttestation(baseURL: String) async {
        isBusy = true
        serverResult = "Requesting a one-time challenge…"
        defer { isBusy = false }

        guard DCAppAttestService.shared.isSupported else {
            serverResult = "FAIL: App Attest unsupported"
            return
        }
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = base.scheme, scheme == "http" || scheme == "https",
              let host = base.host, !host.isEmpty else {
            serverResult = "FAIL: Enter a full URL such as http://mac.local:8788"
            return
        }

        do {
            var challengeRequest = URLRequest(url: base.appending(path: "challenge"))
            challengeRequest.httpMethod = "POST"
            let (challengeData, challengeHTTP) = try await URLSession.shared.data(for: challengeRequest)
            guard (challengeHTTP as? HTTPURLResponse)?.statusCode == 200 else {
                serverResult = "FAIL: Could not get challenge. Check Mac server and URL."
                return
            }
            let challenge = try JSONDecoder().decode(ChallengeResponse.self, from: challengeData)
            let hex = Array(challenge.challenge.utf8)
            guard hex.count == 64 else {
                serverResult = "FAIL: Server returned malformed challenge"
                return
            }
            var challengeBytes = [UInt8]()
            for offset in stride(from: 0, to: hex.count, by: 2) {
                guard let byte = UInt8(String(decoding: hex[offset..<(offset + 2)], as: UTF8.self), radix: 16) else {
                    serverResult = "FAIL: Server returned malformed challenge"
                    return
                }
                challengeBytes.append(byte)
            }

            serverResult = "Asking Apple to attest this challenge…"
            let service = DCAppAttestService.shared
            let keyID = try await service.generateKey()
            let clientDataHash = Data(SHA256.hash(data: Data(challengeBytes)))
            let attestation = try await service.attestKey(keyID, clientDataHash: clientDataHash)

            serverResult = "Checking Apple's certificate on the Mac…"
            var verifyRequest = URLRequest(url: base.appending(path: "verify"))
            verifyRequest.httpMethod = "POST"
            verifyRequest.setValue("application/json", forHTTPHeaderField: "content-type")
            verifyRequest.httpBody = try JSONEncoder().encode(VerifyRequest(
                challengeId: challenge.challengeId,
                keyId: keyID,
                attestationObject: attestation.base64EncodedString()
            ))
            let (verifyData, verifyHTTP) = try await URLSession.shared.data(for: verifyRequest)
            let response = try JSONDecoder().decode(VerifyResponse.self, from: verifyData)
            if (verifyHTTP as? HTTPURLResponse)?.statusCode == 200 && response.verified == true {
                serverResult = "PASS: Mac verified Apple's certificate, app ID, key ID, and one-time challenge."
            } else {
                serverResult = "FAIL: Server rejected attestation (\(response.error ?? "unknown error"))"
            }
        } catch {
            serverResult = "FAIL: \(error.localizedDescription)"
        }
    }
}
