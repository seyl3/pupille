export { verifyProof, verifyFile } from "./verify.ts";
export type { VerifyOptions, VerificationResult, Check, CheckId } from "./verify.ts";
export { embedProof, extractProof, JpegError } from "./jpeg.ts";
export { proofFromFeedPost, parseProof } from "./proof.ts";
export type { PupilleProof, SignedCertificate, FeedPost } from "./proof.ts";

/** Ed25519 issuer key pinned in the Pupille iPhone app. */
export const PUPILLE_ISSUER_PUBLIC_KEY = "46699f0e689eb90902f3a7f3850b7dde146b77389161e3a1caa8d8062da92fb8";
