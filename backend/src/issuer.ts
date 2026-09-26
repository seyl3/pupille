import { generateKeyPairSync, sign as cryptoSign } from "node:crypto";

/**
 * Issuer key (Ed25519), per docs/ARCHITECTURE.md §13: "Backend environment. Public key
 * pinned in the app." Generated fresh per process for this dev/test build — a real deployment
 * persists this key and distributes the public half to the app; that distribution step is
 * iOS-app work and tracked in docs/WORKLOG.md.
 */
const { privateKey, publicKey } = generateKeyPairSync("ed25519");

export function signCertificate(certBytes: Buffer): Buffer {
  return cryptoSign(null, certBytes, privateKey);
}

export function issuerPublicKeyDer(): Buffer {
  return publicKey.export({ type: "spki", format: "der" });
}
