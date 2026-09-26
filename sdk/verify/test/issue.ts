/**
 * Test issuer: builds proofs exactly the way backend/src/routes/onboard.ts and
 * captures.ts do (same certificate fields, tags and encodings), with throwaway keys.
 */
import { concat, sha256, toHex, utf8 } from "../src/bytes.ts";
import type { PupilleProof } from "../src/proof.ts";

const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));

export interface TestIssuer {
  publicKeyHex: string;
  sign(bytes: Uint8Array): Promise<Uint8Array>;
}

export async function makeIssuer(): Promise<TestIssuer> {
  const keys = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey));
  return {
    publicKeyHex: toHex(raw),
    sign: async (bytes) => new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, keys.privateKey, bytes as BufferSource)),
  };
}

export interface CaptureOptions {
  handle?: string;
  caption?: string | null;
  appId?: string;
  environment?: string;
  credential?: string;
}

/** A profile + capture signed like the real backend, over `imageBytes`. */
export async function issueProof(issuer: TestIssuer, imageBytes: Uint8Array, options: CaptureOptions = {}): Promise<PupilleProof> {
  const handle = options.handle ?? "xyz";
  const caption = options.caption === undefined ? "hello tokyo" : options.caption;
  const author = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const publicKey = new Uint8Array(await crypto.subtle.exportKey("raw", author.publicKey));
  const profileId = crypto.getRandomValues(new Uint8Array(16));
  const challenge = crypto.getRandomValues(new Uint8Array(32));
  const assertionHash = await sha256(utf8("test-assertion"));
  const noDepth = new Uint8Array(32);

  const profileCommitment = await sha256(concat(utf8("pupille:profile:v1"), profileId, publicKey, utf8(handle)));
  const profileCert = utf8(JSON.stringify({
    v: 1, type: "profile", issuer: "pupille-backend-1", profileId: toHex(profileId),
    handle, keyVersion: 1, publicKey: b64(publicKey),
    credential: options.credential ?? "proof_of_human", environment: options.environment ?? "staging",
    uniquenessAction: "pupille-profile-v1", worldSession: false, profileCommitment: toHex(profileCommitment),
    validFrom: new Date().toISOString(),
  }));

  const imageHash = await sha256(imageBytes);
  const commitment = await sha256(concat(utf8("pupille:capture:v1"),
    imageHash, noDepth, challenge, assertionHash, profileId, publicKey));
  const postId = "01TEST" + toHex(crypto.getRandomValues(new Uint8Array(6))).toUpperCase();
  const captureCert = utf8(JSON.stringify({
    v: 1, type: "capture", issuer: "pupille-backend-1", postId,
    appId: options.appId ?? "4397GAXGZ4.app.pupille.dev", profileId: toHex(profileId), keyVersion: 1,
    imageSha256: toHex(imageHash), depthSha256: toHex(noDepth),
    captionSha256: caption ? toHex(await sha256(utf8(caption))) : null,
    challenge: toHex(challenge), assertionSha256: toHex(assertionHash),
    captureCommitment: toHex(commitment), challengeIssuedAt: new Date().toISOString(),
    worldSession: false, certifiedAt: new Date().toISOString(),
  }));
  const postSignature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" },
    author.privateKey, concat(utf8("pupille:post-sig:v1"), commitment) as BufferSource));

  return {
    v: 1, type: "pupille-proof", postId, caption, createdAt: new Date().toISOString(),
    author: { handle, profileId: toHex(profileId), publicKey: b64(publicKey) },
    postSignature: b64(postSignature),
    profileCert: { certB64: b64(profileCert), sigB64: b64(await issuer.sign(profileCert)) },
    captureCert: { certB64: b64(captureCert), sigB64: b64(await issuer.sign(captureCert)) },
  };
}
