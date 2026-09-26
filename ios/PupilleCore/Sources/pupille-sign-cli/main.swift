import PupilleCore
import Foundation

// Cross-language ECDSA round-trip bridge for backend/test: Swift signs a message with a
// fresh software P-256 key (see SoftwareProfileKey — a swift-crypto stand-in for
// SecureEnclave.P256, not hardware-backed) and prints the public key + signature as hex,
// so Node can verify them with `dsaEncoding: "ieee-p1363"` per docs/ARCHITECTURE.md §06.
//
// Usage: pupille-sign-cli <message-utf8>
// Output (stdout, two lines): <65-byte-X9.63-pubkey-hex>\n<64-byte-r‖s-sig-hex>

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: pupille-sign-cli <message>\n".data(using: .utf8)!)
    exit(1)
}

let message = Array(CommandLine.arguments[1].utf8)
let key = SoftwareProfileKey()
let signature = try key.sign(message)

print(CaptureHasher.hex(key.publicKeyX963))
print(CaptureHasher.hex(signature))
