/**
 * tools/fake-phone: plays the client (iPhone) role against a REAL RUNNING Pupille backend,
 * since there is no physical iPhone / Secure Enclave / App Attest / World App available in this
 * environment. Drives the full create-profile -> capture -> publish -> feed-fetch -> verify
 * chain over real HTTP. Exits 0 only if every step succeeds and the fetched post verifies;
 * exits non-zero (with the failing step printed) on any check failure. See docs/WORKLOG.md for
 * exactly which parts of this are stand-ins (profile key, App Attest, World proofs) versus real
 * (the HTTP calls, the backend's own verification logic, the DB, ProofVerifier-equivalent checks
 * run here in TS against the fetched feed payload).
 */
import { randomBytes, createHash } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { SoftwareProfileKey } from "./softwareProfileKey.js";
import { buildFakeAttestation } from "./fakeAppAttest.js";
import {
  profileCommitment,
  profileSignal,
  profilePoPMessage,
  captureCommitment,
  worldSignal,
  postSignatureMessage,
  imageHash,
  depthHash,
  assertionHash,
  hashSignal,
  hex,
} from "../../../backend/src/proto/captureHasher.js";
import { verifyProfileSignature } from "../../../backend/src/proto/profileKey.js";

const BASE_URL = process.env.PUPILLE_BACKEND_URL ?? "http://localhost:8787";
const APP_ID = process.env.PUPILLE_APP_ID ?? "test.pupille";
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TEST_ROOT_DIR = process.env.PUPILLE_TEST_ROOT_DIR ?? path.join(__dirname, "..", ".test-root");

class StepError extends Error {
  constructor(step: string, detail: string) {
    super(`[${step}] ${detail}`);
  }
}

async function callJson(path: string, init?: RequestInit): Promise<{ status: number; body: any }> {
  const res = await fetch(`${BASE_URL}${path}`, {
    ...init,
    headers: { "content-type": "application/json", ...(init?.headers ?? {}) },
  });
  const text = await res.text();
  let body: any;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    body = { rawText: text };
  }
  return { status: res.status, body };
}

/** Builds a hand-shaped World verify-API response fixture — see docs/WORKLOG.md for field-name caveats. */
function fakeWorldResult(signal: string, kind: "uniqueness" | "session", sessionId?: string) {
  const base = {
    success: true,
    signal_hash: hashSignal(signal),
    identifier: "11",
    issuer_schema_id: "11",
    sybil_score: 1,
    integrity_bundle: { fixture: true, note: "fake-phone stand-in, not a real World App response" },
  };
  if (kind === "uniqueness") {
    return { ...base, nullifier: BigInt("0x" + randomBytes(20).toString("hex")).toString() };
  }
  return {
    ...base,
    session_id: sessionId ?? `session_${randomBytes(64).toString("hex")}`,
    session_nullifier: BigInt("0x" + randomBytes(20).toString("hex")).toString(),
  };
}

async function main() {
  console.log(`fake-phone: driving ${BASE_URL} through the full protocol flow`);

  const health = await fetch(`${BASE_URL}/healthz`).catch(() => null);
  if (!health || !health.ok) {
    throw new StepError("healthcheck", `backend not reachable at ${BASE_URL} — start it first (see docs/WORKLOG.md)`);
  }
  console.log("  [ok] backend is up");

  // --- App Attest registration (fake attestation, real CBOR/COSE parsing on the server) ---
  if (!existsSync(path.join(TEST_ROOT_DIR, "test-root-cert.pem"))) {
    throw new StepError(
      "config",
      `No test root found at ${TEST_ROOT_DIR}. Run: npx tsx src/generateTestRoot.ts ${TEST_ROOT_DIR}, ` +
        `then start the backend with PUPILLE_APP_ATTEST_TEST_ROOT_PEM set to that file's contents ` +
        `(this script cannot register a fake attestation against a backend pinned to Apple's real root, by design).`
    );
  }
  console.log(`  using test root at ${TEST_ROOT_DIR} (backend must be started with matching PUPILLE_APP_ATTEST_TEST_ROOT_PEM)`);

  const attestClientDataHash = createHash("sha256").update("fake-phone-attest").digest();
  const fakeAttestation = await buildFakeAttestation({
    appId: APP_ID,
    clientDataHash: attestClientDataHash,
    testRootDir: TEST_ROOT_DIR,
  });

  const challengeRes = await callJson("/v1/attest/challenge", { method: "POST" });
  if (challengeRes.status !== 200) throw new StepError("attest/challenge", JSON.stringify(challengeRes.body));

  const registerRes = await callJson("/v1/attest/register", {
    method: "POST",
    body: JSON.stringify({
      challengeId: challengeRes.body.challengeId,
      attestationObject: fakeAttestation.attestationObjectCbor.toString("base64"),
      clientDataHash: attestClientDataHash.toString("hex"),
    }),
  });
  if (registerRes.status !== 200) throw new StepError("attest/register", JSON.stringify(registerRes.body));
  const attestKeyId = registerRes.body.keyId as string;
  console.log(`  [ok] fake App Attest key registered (real CBOR/COSE parse on server): ${attestKeyId}`);

  // --- Profile creation ---
  const profileKey = new SoftwareProfileKey();
  const profileId = randomBytes(16);
  const handle = `fake${Date.now().toString(36)}`.slice(0, 20);

  const startRes = await callJson("/v1/profiles/start", {
    method: "POST",
    body: JSON.stringify({ profileId: hex(profileId), publicKey: hex(profileKey.publicKeyX963), handle, attestKeyId }),
  });
  if (startRes.status !== 200) throw new StepError("profiles/start", JSON.stringify(startRes.body));
  const reservationId = startRes.body.reservationId as string;
  console.log(`  [ok] handle reserved: @${handle}`);

  const commitment = profileCommitment(profileId, profileKey.publicKeyX963, handle);
  const signal = profileSignal(commitment);

  const uniqueRes = await callJson("/v1/profiles/unique", {
    method: "POST",
    body: JSON.stringify({ reservationId, result: fakeWorldResult(signal, "uniqueness") }),
  });
  if (uniqueRes.status !== 200) throw new StepError("profiles/unique", JSON.stringify(uniqueRes.body));
  console.log("  [ok] uniqueness proof accepted (fake World proof, real signal_hash + nullifier-claim checks)");

  const sessionResult = fakeWorldResult(signal, "session");
  const profilePoP = profileKey.sign(profilePoPMessage(commitment));

  const completeRes = await callJson("/v1/profiles/complete", {
    method: "POST",
    body: JSON.stringify({
      reservationId,
      nullifier: uniqueRes.body.nullifier,
      result: sessionResult,
      profilePoP: hex(profilePoP),
    }),
  });
  if (completeRes.status !== 200) throw new StepError("profiles/complete", JSON.stringify(completeRes.body));
  console.log(`  [ok] profile @${handle} created, cert issued`);

  // --- Capture + publish ---
  const captureChallengeRes = await callJson("/v1/captures/challenge", {
    method: "POST",
    headers: { "x-profile-id": hex(profileId) },
  });
  if (captureChallengeRes.status !== 200) throw new StepError("captures/challenge", JSON.stringify(captureChallengeRes.body));
  const challengeId = captureChallengeRes.body.challengeId as string;
  const challenge = Buffer.from(captureChallengeRes.body.challenge as string, "hex");

  const imageBytes = Buffer.from(`fake-phone-photo-${Date.now()}`, "utf8");
  const assertion = Buffer.from("fake-phone-assertion-bytes", "utf8"); // stand-in, see docs/WORKLOG.md
  const imgHash = imageHash(imageBytes);
  const dHash = depthHash(null);
  const assertHash = assertionHash(assertion);
  const commitment2 = captureCommitment(imgHash, dHash, challenge, assertHash, profileId, profileKey.publicKeyX963);
  const postSig = profileKey.sign(postSignatureMessage(commitment2));

  const deviceRes = await callJson(`/v1/captures/${challengeId}/device`, {
    method: "POST",
    body: JSON.stringify({
      imageBase64: imageBytes.toString("base64"),
      assertionBase64: assertion.toString("base64"),
      postSignature: hex(postSig),
      profilePublicKey: hex(profileKey.publicKeyX963),
    }),
  });
  if (deviceRes.status !== 200) throw new StepError("captures/device", JSON.stringify(deviceRes.body));
  console.log("  [ok] capture device-side checks passed (postSignature + commitment verified by server)");

  const humanResult = fakeWorldResult(worldSignal(commitment2), "session", sessionResult.session_id);
  const humanRes = await callJson(`/v1/captures/${challengeId}/human`, {
    method: "POST",
    body: JSON.stringify({ result: humanResult, caption: "hello from fake-phone" }),
  });
  if (humanRes.status !== 200) throw new StepError("captures/human", JSON.stringify(humanRes.body));
  const postId = humanRes.body.postId as string;
  console.log(`  [ok] post published: ${postId}`);

  // --- Feed fetch + local verification (mirrors PupilleCore's ProofVerifier, §09 checks) ---
  const feedRes = await fetch(`${BASE_URL}/v1/feed`);
  if (!feedRes.ok) throw new StepError("feed", `status ${feedRes.status}`);
  const feed = (await feedRes.json()) as any[];
  const post = feed.find((p) => p.id === postId);
  if (!post) throw new StepError("feed", `published post ${postId} not found in feed`);

  const imageRes = await fetch(`${BASE_URL}${post.imageUrl}`);
  const downloadedImage = Buffer.from(await imageRes.arrayBuffer());
  if (!downloadedImage.equals(imageBytes)) {
    throw new StepError("verify", "downloaded image bytes do not match what was uploaded");
  }

  const captureCertJson = JSON.parse(Buffer.from(post.captureCert.certB64, "base64").toString("utf8"));
  const recomputedImageHash = hex(imageHash(downloadedImage));
  if (recomputedImageHash !== captureCertJson.imageSha256) {
    throw new StepError("verify", "check 4 failed: downloaded image hash does not match capture cert");
  }

  const postSignatureValid = verifyProfileSignature(
    Buffer.from(post.postSignature, "base64"),
    postSignatureMessage(Buffer.from(captureCertJson.captureCommitment, "hex")),
    Buffer.from(post.author.publicKey, "base64")
  );
  if (!postSignatureValid) {
    throw new StepError("verify", "check 6 failed: postSignature does not verify under the author's public key");
  }

  console.log("  [ok] feed fetch + local checks passed: image bytes match, postSignature verifies");
  console.log("\nfake-phone: full chain succeeded (create-profile -> capture -> publish -> feed-fetch -> verify)");
}

main().catch((err) => {
  console.error("\nfake-phone FAILED:", err instanceof Error ? err.message : err);
  process.exit(1);
});
