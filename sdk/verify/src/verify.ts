import { concat, fromBase64, fromHex, sha256, toHex, utf8 } from "./bytes.ts";
import { extractProof } from "./jpeg.ts";
import type { PupilleProof } from "./proof.ts";

export interface VerifyOptions {
  /** The issuer's Ed25519 public key: 32 raw bytes, or 64 hex characters. */
  issuerPublicKey: Uint8Array | string;
  /**
   * App Attest app IDs (`TEAMID.bundle.id`) whose captures you accept.
   * Leave undefined to accept any app the issuer certified.
   */
  trustedAppIds?: string[];
}

export type CheckId =
  | "human" | "author" | "capture" | "bytes" | "caption" | "commitment" | "signature" | "app";

export interface Check {
  id: CheckId;
  title: string;
  passed: boolean;
}

export interface VerificationResult {
  /** True only when every check passed. */
  verified: boolean;
  checks: Check[];
  handle?: string;
  /** World environment of the author's Proof of Human: "staging" or "production". */
  environment?: string;
  /** App Attest app ID the issuer certified the capture for. */
  appId?: string;
  postId?: string;
}

interface ProfileCertificate {
  profileId: string; handle: string; keyVersion: number;
  publicKey: string; credential: string; environment?: string;
}

interface CaptureCertificate {
  postId?: string; appId?: string; profileId: string; keyVersion: number;
  imageSha256: string; depthSha256: string; captionSha256: string | null;
  challenge: string; assertionSha256: string; captureCommitment: string;
}

const NO_DEPTH = new Uint8Array(32);

async function verifyEd25519(publicKey: Uint8Array, signature: Uint8Array, message: Uint8Array): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey("raw", publicKey as BufferSource, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, signature as BufferSource, message as BufferSource);
  } catch {
    return false;
  }
}

/** ECDSA P-256 / SHA-256 over a raw r‖s signature, which is WebCrypto's native format. */
async function verifyP256(x963: Uint8Array, signature: Uint8Array, message: Uint8Array): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey("raw", x963 as BufferSource,
      { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key,
      signature as BufferSource, message as BufferSource);
  } catch {
    return false;
  }
}

function decodeJSON<T>(bytes: Uint8Array | null): T | null {
  if (!bytes) return null;
  try { return JSON.parse(new TextDecoder().decode(bytes)) as T; } catch { return null; }
}

/**
 * Verifies a proof against the exact image bytes it claims to cover. Pure and offline:
 * it trusts only `issuerPublicKey`, never a "verified" flag from a server.
 *
 * The checks match the Pupille app's proof sheet, plus an optional trusted-app check.
 */
export async function verifyProof(
  proof: PupilleProof, imageBytes: Uint8Array, options: VerifyOptions,
): Promise<VerificationResult> {
  const issuerKey = typeof options.issuerPublicKey === "string"
    ? fromHex(options.issuerPublicKey) : options.issuerPublicKey;

  const profileBytes = fromBase64(proof.profileCert.certB64);
  const captureBytes = fromBase64(proof.captureCert.certB64);
  const profileSig = fromBase64(proof.profileCert.sigB64);
  const captureSig = fromBase64(proof.captureCert.sigB64);
  const profileSigned = !!(issuerKey && profileBytes && profileSig)
    && await verifyEd25519(issuerKey, profileSig, profileBytes);
  const captureSigned = !!(issuerKey && captureBytes && captureSig)
    && await verifyEd25519(issuerKey, captureSig, captureBytes);
  const profile = decodeJSON<ProfileCertificate>(profileBytes);
  const capture = decodeJSON<CaptureCertificate>(captureBytes);

  const imageDigest = await sha256(imageBytes);
  const worldCredential = profile?.credential === "proof_of_human"
    && ["staging", "production"].includes(profile?.environment ?? "");
  const authorMatches = !!profile && profile.handle === proof.author.handle
    && profile.profileId === proof.author.profileId
    && profile.publicKey === proof.author.publicKey;
  const captureMatches = !!capture && capture.profileId === profile?.profileId
    && capture.keyVersion === profile?.keyVersion
    && capture.depthSha256 === toHex(NO_DEPTH);
  const bytesMatch = capture?.imageSha256 === toHex(imageDigest);

  let captionMatches: boolean;
  if (proof.caption) {
    captionMatches = capture?.captionSha256 === toHex(await sha256(utf8(proof.caption)));
  } else {
    captionMatches = !!capture && capture.captionSha256 == null;
  }

  // Recompute the commitment from the bytes we hold, not the one the certificate states.
  let commitment: Uint8Array | null = null;
  const profileId = profile && fromHex(profile.profileId);
  const publicKey = profile && fromBase64(profile.publicKey);
  const challenge = capture && fromHex(capture.challenge);
  const assertionHash = capture && fromHex(capture.assertionSha256);
  if (profileId && publicKey && challenge && assertionHash) {
    commitment = await sha256(concat(utf8("pupille:capture:v1"),
      imageDigest, NO_DEPTH, challenge, assertionHash, profileId, publicKey));
  }
  const commitmentMatches = !!commitment && toHex(commitment) === capture?.captureCommitment;

  const postSignature = fromBase64(proof.postSignature);
  const authorSigned = !!(commitment && publicKey && postSignature)
    && await verifyP256(publicKey, postSignature, concat(utf8("pupille:post-sig:v1"), commitment));

  const checks: Check[] = [
    { id: "human", title: "World Human credential certified at signup", passed: profileSigned && worldCredential },
    { id: "author", title: "Profile belongs to this author", passed: authorMatches },
    { id: "capture", title: "Device capture certified by Pupille", passed: captureSigned && captureMatches },
    { id: "bytes", title: "Exact photo bytes match", passed: bytesMatch },
    { id: "caption", title: "Caption matches", passed: captionMatches },
    { id: "commitment", title: "Capture commitment matches", passed: commitmentMatches },
    { id: "signature", title: "Author signed this capture", passed: authorSigned },
  ];
  if (options.trustedAppIds) {
    checks.push({
      id: "app", title: "Captured in a trusted app",
      passed: captureSigned && !!capture?.appId && options.trustedAppIds.includes(capture.appId),
    });
  }

  return {
    verified: checks.every((c) => c.passed),
    checks,
    handle: profile?.handle,
    environment: profile?.environment,
    appId: capture?.appId,
    postId: capture?.postId ?? proof.postId,
  };
}

/**
 * Verifies a JPEG that carries its own proof (see `embedProof`).
 * Returns `null` when the file has no Pupille proof.
 */
export async function verifyFile(file: Uint8Array, options: VerifyOptions): Promise<VerificationResult | null> {
  const { proof, imageBytes } = extractProof(file);
  return proof ? verifyProof(proof, imageBytes, options) : null;
}
