import { generateKeyPairSync, sign as cryptoSign } from "node:crypto";

/**
 * Node-side software P-256 key for backend integration tests, standing in for a real device's
 * SecureEnclave-backed profile key — NOT hardware-backed, never used outside test/fixture code.
 * Mirrors ios/PupilleCore's SoftwareProfileKey (also a swift-crypto stand-in) so both language
 * test suites use an equivalently-labeled non-hardware substitute rather than each inventing
 * their own ad hoc key type.
 */
export class SoftwareProfileKeyForTests {
  private privateKey;
  public publicKeyX963: Buffer;

  constructor() {
    const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
    this.privateKey = privateKey;
    // Export as X9.63 uncompressed (0x04 || X || Y) via the 'raw' Node.js export where available;
    // Node exposes this through the JWK -> manual concat path for portability across Node versions.
    const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
    const x = Buffer.from(jwk.x, "base64url");
    const y = Buffer.from(jwk.y, "base64url");
    this.publicKeyX963 = Buffer.concat([Buffer.from([0x04]), x, y]);
  }

  sign(message: Buffer): Buffer {
    return cryptoSign(null, message, { key: this.privateKey, dsaEncoding: "ieee-p1363" });
  }
}
