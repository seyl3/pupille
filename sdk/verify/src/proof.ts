/**
 * A Pupille proof bundle: everything a verifier needs besides the image bytes.
 * The fields are the ones `GET /v1/feed` already returns, kept as exact bytes.
 */
export interface PupilleProof {
  v: 1;
  type: "pupille-proof";
  postId: string;
  caption: string | null;
  createdAt?: string;
  author: { handle: string; profileId: string; publicKey: string };
  /** Base64 raw r‖s ECDSA P-256 signature by the author's Secure Enclave key. */
  postSignature: string;
  profileCert: SignedCertificate;
  captureCert: SignedCertificate;
}

/** Issuer-signed JSON certificate, as exact base64 bytes plus an Ed25519 signature. */
export interface SignedCertificate {
  certB64: string;
  sigB64: string;
}

/** The subset of a `GET /v1/feed` post the proof is built from. */
export interface FeedPost {
  id: string;
  caption: string | null;
  createdAt?: string;
  author: { handle: string; profileId: string; publicKey: string };
  postSignature: string;
  profileCert: SignedCertificate;
  captureCert: SignedCertificate;
}

export function proofFromFeedPost(post: FeedPost): PupilleProof {
  return {
    v: 1,
    type: "pupille-proof",
    postId: post.id,
    caption: post.caption ?? null,
    createdAt: post.createdAt,
    author: { handle: post.author.handle, profileId: post.author.profileId, publicKey: post.author.publicKey },
    postSignature: post.postSignature,
    profileCert: post.profileCert,
    captureCert: post.captureCert,
  };
}

export function parseProof(json: string): PupilleProof | null {
  try {
    const value = JSON.parse(json) as PupilleProof;
    const ok = value?.v === 1 && value.type === "pupille-proof"
      && typeof value.postSignature === "string"
      && typeof value.author?.publicKey === "string"
      && typeof value.profileCert?.certB64 === "string"
      && typeof value.captureCert?.certB64 === "string";
    return ok ? value : null;
  } catch {
    return null;
  }
}
