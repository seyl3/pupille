import { generateKeyPairSync, sign as cryptoSign } from "node:crypto";

/**
 * STAND-IN FOR SECURE ENCLAVE — NOT REAL HARDWARE.
 *
 * A real iPhone signs with `SecureEnclave.P256.Signing.PrivateKey` (non-exportable, Face ID
 * gated). This is a plain software P-256 key used only so this script can play the client role
 * against a real backend without an iPhone. Never present output from this key as a real device
 * attestation to anything other than this fake-phone script's own backend calls.
 */
export class SoftwareProfileKey {
  private privateKey;
  public readonly publicKeyX963: Buffer;

  constructor() {
    const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
    this.privateKey = privateKey;
    const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
    this.publicKeyX963 = Buffer.concat([
      Buffer.from([0x04]),
      Buffer.from(jwk.x, "base64url"),
      Buffer.from(jwk.y, "base64url"),
    ]);
  }

  sign(message: Buffer): Buffer {
    return cryptoSign(null, message, { key: this.privateKey, dsaEncoding: "ieee-p1363" });
  }
}
