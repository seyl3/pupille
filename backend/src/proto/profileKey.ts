import { createPublicKey, verify as cryptoVerify } from "node:crypto";

/**
 * Verifies a raw r‖s P-256 signature (as produced by CryptoKit/swift-crypto's
 * `.rawRepresentation`) against a 65-byte X9.63 public key, per docs/ARCHITECTURE.md §06.
 */
export function x963ToKeyObject(publicKeyX963: Buffer) {
  if (publicKeyX963.length !== 65 || publicKeyX963[0] !== 0x04) {
    throw new Error("expected 65-byte uncompressed X9.63 public key (0x04 || X || Y)");
  }
  const x = publicKeyX963.subarray(1, 33);
  const y = publicKeyX963.subarray(33, 65);
  const jwk = {
    kty: "EC",
    crv: "P-256",
    x: x.toString("base64url"),
    y: y.toString("base64url"),
  };
  return createPublicKey({ key: jwk, format: "jwk" });
}

export function verifyProfileSignature(signature: Buffer, message: Buffer, publicKeyX963: Buffer): boolean {
  if (signature.length !== 64) return false;
  const keyObject = x963ToKeyObject(publicKeyX963);
  return cryptoVerify("sha256", message, { key: keyObject, dsaEncoding: "ieee-p1363" }, signature);
}
