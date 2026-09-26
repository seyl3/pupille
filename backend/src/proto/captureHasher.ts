import { createHash } from "node:crypto";
import { hashSignal as idkitHashSignal } from "@worldcoin/idkit-core/hashing";

/**
 * Byte-exact protocol derivations from docs/ARCHITECTURE.md §06.
 * Must produce output identical to ios/PupilleCore/Sources/PupilleCore/CaptureHasher.swift;
 * both are checked against the shared fixture in test/fixtures/section06-vectors.json.
 */

const tag = (s: string): Buffer => Buffer.from(s, "ascii");

export function sha256(data: Buffer): Buffer {
  return createHash("sha256").update(data).digest();
}

export function hex(data: Buffer): string {
  return data.toString("hex");
}

export function hexDecode(s: string): Buffer {
  if (s.length % 2 !== 0) throw new Error("odd-length hex string");
  return Buffer.from(s, "hex");
}

// --- Profile creation / key rotation ---

export function profileCommitment(profileId: Buffer, profilePublicKey: Buffer, handle: string): Buffer {
  return sha256(Buffer.concat([tag("pupille:profile:v1"), profileId, profilePublicKey, Buffer.from(handle, "utf8")]));
}

export function profileSignal(commitment: Buffer): string {
  return "0x" + hex(commitment);
}

export function profilePoPMessage(commitment: Buffer): Buffer {
  return Buffer.concat([tag("pupille:profile-sig:v1"), commitment]);
}

/**
 * clientDataHash for the App Attest assertion made at profile creation/rotation, per §07's
 * backend-checks line: "App Attest assertion over H('pupille:profile-assert:v1' || profileCommitment)".
 * Distinct from the per-capture clientDataHash (`"pupille:assert:v1"`), which hashes different fields.
 */
export function profileAssertClientDataHash(commitment: Buffer): Buffer {
  return sha256(Buffer.concat([tag("pupille:profile-assert:v1"), commitment]));
}

// --- Per capture ---

export function imageHash(imageBytes: Buffer): Buffer {
  return sha256(imageBytes);
}

/** 32 zero bytes when depth is absent, per §06. */
export function depthHash(depthBytes: Buffer | null): Buffer {
  if (depthBytes === null) return Buffer.alloc(32, 0);
  return sha256(depthBytes);
}

export function clientDataHash(imgHash: Buffer, dHash: Buffer, challenge: Buffer): Buffer {
  return sha256(Buffer.concat([tag("pupille:assert:v1"), imgHash, dHash, challenge]));
}

export function assertionHash(assertion: Buffer): Buffer {
  return sha256(assertion);
}

export function captureCommitment(
  imgHash: Buffer,
  dHash: Buffer,
  challenge: Buffer,
  assertHash: Buffer,
  profileId: Buffer,
  profilePublicKey: Buffer
): Buffer {
  return sha256(
    Buffer.concat([tag("pupille:capture:v1"), imgHash, dHash, challenge, assertHash, profileId, profilePublicKey])
  );
}

export function postSignatureMessage(commitment: Buffer): Buffer {
  return Buffer.concat([tag("pupille:post-sig:v1"), commitment]);
}

export function worldSignal(commitment: Buffer): string {
  return "0x" + hex(commitment);
}

// --- World signal hash: use IDKit's real helper, never a hand-rolled keccak. ---

export function hashSignal(signal: string): string {
  return idkitHashSignal(signal);
}

// --- Auth ---

export function authSignatureMessage(authChallenge: Buffer): Buffer {
  return Buffer.concat([tag("pupille:auth:v1"), authChallenge]);
}

export function worldProofHash(exactResultJsonBytes: Buffer): Buffer {
  return sha256(exactResultJsonBytes);
}
