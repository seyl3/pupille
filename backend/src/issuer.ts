import { createPrivateKey, createPublicKey, generateKeyPairSync, sign as cryptoSign } from "node:crypto";
import { readFileSync } from "node:fs";

/**
 * Issuer key (Ed25519), per docs/ARCHITECTURE.md §13: "Backend environment. Public key
 * pinned in the app." Generated fresh per process for this dev/test build — a real deployment
 * persists this key and distributes the public half to the app; that distribution step is
 * iOS-app work and tracked in docs/WORKLOG.md.
 */
const keyPath = process.env.PUPILLE_ISSUER_PRIVATE_KEY_PATH;
if (process.env.NODE_ENV === "production" && !keyPath) {
  throw new Error("PUPILLE_ISSUER_PRIVATE_KEY_PATH is required in production");
}
const privateKey = keyPath ? createPrivateKey(readFileSync(keyPath)) : generateKeyPairSync("ed25519").privateKey;
const publicKey = createPublicKey(privateKey);

export function signCertificate(certBytes: Buffer): Buffer {
  return cryptoSign(null, certBytes, privateKey);
}

export function issuerPublicKeyDer(): Buffer {
  return publicKey.export({ type: "spki", format: "der" });
}
