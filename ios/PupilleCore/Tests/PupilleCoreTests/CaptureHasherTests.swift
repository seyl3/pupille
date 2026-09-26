import XCTest
@testable import PupilleCore

final class CaptureHasherTests: XCTestCase {
    struct Vectors: Decodable {
        struct Inputs: Decodable {
            let imageBytesAscii: String
            let depthBytesAscii: String
            let challengeHex: String
            let assertionAscii: String
            let profileIdHex: String
            let profilePublicKeyHex: String
            let handle: String
        }
        struct Expected: Decodable {
            let profileCommitment: String
            let imageHash: String
            let depthHash: String
            let clientDataHash: String
            let assertionHash: String
            let captureCommitment: String
            let clientDataHashNoDepth: String
            let captureCommitmentNoDepth: String
            let signalHashProfileSignal: String
            let signalHashWorldSignal: String
            let signalHashWorldSignalNoDepth: String
        }
        let inputs: Inputs
        let expected: Expected
    }

    static func loadVectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "section06-vectors", withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    func testSection06Vectors() throws {
        let v = try Self.loadVectors()
        let imageBytes = Array(v.inputs.imageBytesAscii.utf8)
        let depthBytes = Array(v.inputs.depthBytesAscii.utf8)
        let challenge = CaptureHasher.hexDecode(v.inputs.challengeHex)!
        let assertion = Array(v.inputs.assertionAscii.utf8)
        let profileId = CaptureHasher.hexDecode(v.inputs.profileIdHex)!
        let profilePublicKey = CaptureHasher.hexDecode(v.inputs.profilePublicKeyHex)!
        let handle = v.inputs.handle

        let profileCommitment = CaptureHasher.profileCommitment(
            profileId: profileId, profilePublicKey: profilePublicKey, handle: handle
        )
        XCTAssertEqual(CaptureHasher.hex(profileCommitment), v.expected.profileCommitment)

        let imageHash = CaptureHasher.imageHash(imageBytes: imageBytes)
        XCTAssertEqual(CaptureHasher.hex(imageHash), v.expected.imageHash)

        let depthHash = CaptureHasher.depthHash(depthBytes: depthBytes)
        XCTAssertEqual(CaptureHasher.hex(depthHash), v.expected.depthHash)

        let clientDataHash = CaptureHasher.clientDataHash(imageHash: imageHash, depthHash: depthHash, challenge: challenge)
        XCTAssertEqual(CaptureHasher.hex(clientDataHash), v.expected.clientDataHash)

        let assertionHash = CaptureHasher.assertionHash(assertion: assertion)
        XCTAssertEqual(CaptureHasher.hex(assertionHash), v.expected.assertionHash)

        let captureCommitment = CaptureHasher.captureCommitment(
            imageHash: imageHash, depthHash: depthHash, challenge: challenge,
            assertionHash: assertionHash, profileId: profileId, profilePublicKey: profilePublicKey
        )
        XCTAssertEqual(CaptureHasher.hex(captureCommitment), v.expected.captureCommitment)

        // No-depth variant: depthHash is 32 zero bytes.
        let noDepthHash = CaptureHasher.depthHash(depthBytes: nil)
        XCTAssertEqual(noDepthHash, [UInt8](repeating: 0, count: 32))

        let clientDataHashNoDepth = CaptureHasher.clientDataHash(imageHash: imageHash, depthHash: noDepthHash, challenge: challenge)
        XCTAssertEqual(CaptureHasher.hex(clientDataHashNoDepth), v.expected.clientDataHashNoDepth)

        let captureCommitmentNoDepth = CaptureHasher.captureCommitment(
            imageHash: imageHash, depthHash: noDepthHash, challenge: challenge,
            assertionHash: assertionHash, profileId: profileId, profilePublicKey: profilePublicKey
        )
        XCTAssertEqual(CaptureHasher.hex(captureCommitmentNoDepth), v.expected.captureCommitmentNoDepth)

        // Signals and signal_hash.
        let profileSignal = CaptureHasher.profileSignal(profileCommitment: profileCommitment)
        XCTAssertEqual(CaptureHasher.hashSignal(profileSignal), v.expected.signalHashProfileSignal)

        let worldSignal = CaptureHasher.worldSignal(captureCommitment: captureCommitment)
        XCTAssertEqual(CaptureHasher.hashSignal(worldSignal), v.expected.signalHashWorldSignal)

        let worldSignalNoDepth = CaptureHasher.worldSignal(captureCommitment: captureCommitmentNoDepth)
        XCTAssertEqual(CaptureHasher.hashSignal(worldSignalNoDepth), v.expected.signalHashWorldSignalNoDepth)
    }

    func testHashSignalHashesNonHexSignalsAsUTF8() {
        // A string that is NOT 0x+even-hex must be hashed as UTF-8 text, per §06 / IDKit's documented behavior.
        // Expected value obtained by actually running hashSignal("hello") from the real
        // @worldcoin/idkit-core/hashing npm package (v4.3.0) on this machine.
        XCTAssertEqual(
            CaptureHasher.hashSignal("hello"),
            "0x001c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36dea"
        )
    }

    func testProfileKeyRoundTrip() throws {
        let key = SoftwareProfileKey()
        let message = Array("test message".utf8)
        let signature = try key.sign(message)
        XCTAssertEqual(signature.count, 64) // raw r‖s
        XCTAssertEqual(key.publicKeyX963.count, 65) // 0x04 || X || Y
        XCTAssertTrue(ProfileKeyVerifier.verify(signature: signature, message: message, publicKeyX963: key.publicKeyX963))

        // Tampered message must fail verification.
        let tampered = Array("test messagE".utf8)
        XCTAssertFalse(ProfileKeyVerifier.verify(signature: signature, message: tampered, publicKeyX963: key.publicKeyX963))
    }
}
