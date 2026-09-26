import { describe, it, expect, beforeAll, afterAll, beforeEach } from "vitest";
import type pg from "pg";
import { createApp } from "../src/app.js";
import { makeTestPool, truncateAll } from "./testDb.js";
import { buildAppAttestFixture } from "./fixtures/buildAppAttestFixture.js";
import { buildWorldProofFixture } from "./fixtures/worldProofFixture.js";
import { SoftwareProfileKeyForTests } from "./fixtures/softwareKey.js";
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
  hex,
} from "../src/proto/captureHasher.js";

let pool: pg.Pool;
let app: ReturnType<typeof createApp>;

beforeAll(async () => {
  pool = await makeTestPool();
  app = createApp(pool);
});

afterAll(async () => {
  await pool.end();
});

beforeEach(async () => {
  await truncateAll(pool);
});

async function registerAttestKey(appId: string) {
  const clientDataHash = Buffer.alloc(32, 0x11);
  const fixture = await buildAppAttestFixture({ appId, clientDataHash });
  const rootPem = pemFromDer(fixture.rootCertDer);

  // Register directly against the DB using the same verify function the route uses, since the
  // route pins Apple's real root — this test's fixture is signed by a throwaway test CA (see
  // buildAppAttestFixture's doc comment), so we insert directly here rather than fight the pin.
  const { verifyAttestation } = await import("../src/appattest/verify.js");
  const result = await verifyAttestation(fixture.attestationObjectCbor, clientDataHash, appId, rootPem);
  await pool.query(
    `insert into app_attest_keys (key_id, public_key, receipt, counter) values ($1, $2, $3, $4)`,
    [result.keyId, result.publicKeyX963, result.receiptCbor, result.counter]
  );
  return result.keyId;
}

function pemFromDer(der: Buffer): string {
  const b64 = der.toString("base64");
  const lines = b64.match(/.{1,64}/g) ?? [];
  return `-----BEGIN CERTIFICATE-----\n${lines.join("\n")}\n-----END CERTIFICATE-----`;
}

async function createProfile(handle: string) {
  const attestKeyId = await registerAttestKey("test.pupille");
  const key = new SoftwareProfileKeyForTests();
  const profileId = Buffer.from(Array.from({ length: 16 }, (_, i) => i + 1));

  const startRes = await app.request("/v1/profiles/start", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      profileId: hex(profileId),
      publicKey: hex(key.publicKeyX963),
      handle,
      attestKeyId,
    }),
  });
  expect(startRes.status).toBe(200);
  const { reservationId } = (await startRes.json()) as { reservationId: string };

  const commitment = profileCommitment(profileId, key.publicKeyX963, handle);
  const signal = profileSignal(commitment);
  const uniqueResult = buildWorldProofFixture({ signal, kind: "uniqueness" });

  const uniqueRes = await app.request("/v1/profiles/unique", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ reservationId, result: uniqueResult }),
  });
  expect(uniqueRes.status).toBe(200);
  const { nullifier } = (await uniqueRes.json()) as { nullifier: string };

  const sessionResult = buildWorldProofFixture({ signal, kind: "session" });
  const profilePoP = key.sign(profilePoPMessage(commitment));

  const completeRes = await app.request("/v1/profiles/complete", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ reservationId, nullifier, result: sessionResult, profilePoP: hex(profilePoP) }),
  });
  expect(completeRes.status).toBe(200);
  const completeBody = await completeRes.json();

  return { profileId, key, handle, sessionId: sessionResult.session_id!, completeBody };
}

describe("full profile-creation → capture → publish → feed chain (real Postgres, fixture World proofs)", () => {
  it("creates a profile end to end", async () => {
    const { handle, completeBody } = await createProfile("alice");
    expect((completeBody as any).handle).toBe(handle);
    expect((completeBody as any).profileCert.certB64).toBeTruthy();
  });

  it("refuses a second profile for the same World ID nullifier", async () => {
    const attestKeyId = await registerAttestKey("test.pupille");
    const key1 = new SoftwareProfileKeyForTests();
    const profileId1 = Buffer.alloc(16, 1);
    const startRes1 = await app.request("/v1/profiles/start", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ profileId: hex(profileId1), publicKey: hex(key1.publicKeyX963), handle: "bob", attestKeyId }),
    });
    const { reservationId: r1 } = (await startRes1.json()) as { reservationId: string };
    const commitment1 = profileCommitment(profileId1, key1.publicKeyX963, "bob");
    const sharedNullifierResult = buildWorldProofFixture({ signal: profileSignal(commitment1), kind: "uniqueness" });
    const uniqueRes1 = await app.request("/v1/profiles/unique", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ reservationId: r1, result: sharedNullifierResult }),
    });
    expect(uniqueRes1.status).toBe(200);

    // Second profile attempt, different handle/key, but SAME nullifier (same human).
    const key2 = new SoftwareProfileKeyForTests();
    const profileId2 = Buffer.alloc(16, 2);
    const startRes2 = await app.request("/v1/profiles/start", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ profileId: hex(profileId2), publicKey: hex(key2.publicKeyX963), handle: "eve", attestKeyId }),
    });
    const { reservationId: r2 } = (await startRes2.json()) as { reservationId: string };
    const commitment2 = profileCommitment(profileId2, key2.publicKeyX963, "eve");
    // Force the SAME nullifier as before to simulate the same World ID trying again.
    const replayResult = { ...buildWorldProofFixture({ signal: profileSignal(commitment2), kind: "uniqueness" }), nullifier: sharedNullifierResult.nullifier };
    const uniqueRes2 = await app.request("/v1/profiles/unique", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ reservationId: r2, result: replayResult }),
    });
    expect(uniqueRes2.status).toBe(409);
    const body2 = await uniqueRes2.json();
    expect((body2 as any).error).toBe("one_profile_per_human");
  });

  it("captures a photo and publishes it, then it appears verifiably in the feed", async () => {
    const { profileId, key } = await createProfile("carol");

    const challengeRes = await app.request("/v1/captures/challenge", {
      method: "POST",
      headers: { "x-profile-id": hex(profileId) },
    });
    expect(challengeRes.status).toBe(200);
    const { challengeId, challenge: challengeHex } = (await challengeRes.json()) as {
      challengeId: string;
      challenge: string;
    };
    const challenge = Buffer.from(challengeHex, "hex");

    const imageBytes = Buffer.from("integration-test-image-bytes", "utf8");
    const assertion = Buffer.from("fixture-assertion-bytes", "utf8");
    const imgHash = imageHash(imageBytes);
    const dHash = depthHash(null);
    const assertHash = assertionHash(assertion);
    const commitment = captureCommitment(imgHash, dHash, challenge, assertHash, profileId, key.publicKeyX963);
    const postSig = key.sign(postSignatureMessage(commitment));

    const deviceRes = await app.request(`/v1/captures/${challengeId}/device`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        imageBase64: imageBytes.toString("base64"),
        assertionBase64: assertion.toString("base64"),
        postSignature: hex(postSig),
        profilePublicKey: hex(key.publicKeyX963),
      }),
    });
    expect(deviceRes.status).toBe(200);

    const humanResult = buildWorldProofFixture({ signal: worldSignal(commitment), kind: "session" });
    // The session proof must carry the SAME session_id the profile was created with, per §08 —
    // buildWorldProofFixture defaults to a fresh random one, so we can't reuse it blindly here;
    // fetch it back from the profile row to build a session-consistent fixture.
    const profileRow = await pool.query("select session_id from profiles where id = $1", [profileId]);
    const consistentResult = { ...humanResult, session_id: profileRow.rows[0].session_id };

    const humanRes = await app.request(`/v1/captures/${challengeId}/human`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ result: consistentResult, caption: "hello world" }),
    });
    expect(humanRes.status).toBe(200);
    const { postId } = (await humanRes.json()) as { postId: string };
    expect(postId).toBeTruthy();

    const feedRes = await app.request("/v1/feed");
    expect(feedRes.status).toBe(200);
    const feed = (await feedRes.json()) as any[];
    expect(feed.length).toBe(1);
    expect(feed[0].id).toBe(postId);
    expect(feed[0].caption).toBe("hello world");

    const imageRes = await app.request(`/v1/posts/${postId}/image`);
    expect(imageRes.status).toBe(200);
    const downloadedBytes = Buffer.from(await imageRes.arrayBuffer());
    expect(downloadedBytes.equals(imageBytes)).toBe(true);
  });

  it("rejects a replayed session_nullifier on a second /human call", async () => {
    const { profileId, key } = await createProfile("dave");
    const challengeRes = await app.request("/v1/captures/challenge", {
      method: "POST",
      headers: { "x-profile-id": hex(profileId) },
    });
    const { challengeId, challenge: challengeHex } = (await challengeRes.json()) as {
      challengeId: string;
      challenge: string;
    };
    const challenge = Buffer.from(challengeHex, "hex");
    const imageBytes = Buffer.from("replay-test-image", "utf8");
    const assertion = Buffer.from("fixture-assertion-bytes-2", "utf8");
    const imgHash = imageHash(imageBytes);
    const dHash = depthHash(null);
    const assertHash = assertionHash(assertion);
    const commitment = captureCommitment(imgHash, dHash, challenge, assertHash, profileId, key.publicKeyX963);
    const postSig = key.sign(postSignatureMessage(commitment));

    await app.request(`/v1/captures/${challengeId}/device`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        imageBase64: imageBytes.toString("base64"),
        assertionBase64: assertion.toString("base64"),
        postSignature: hex(postSig),
        profilePublicKey: hex(key.publicKeyX963),
      }),
    });

    const profileRow = await pool.query("select session_id from profiles where id = $1", [profileId]);
    const humanResult = {
      ...buildWorldProofFixture({ signal: worldSignal(commitment), kind: "session" }),
      session_id: profileRow.rows[0].session_id,
    };

    const firstHuman = await app.request(`/v1/captures/${challengeId}/human`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ result: humanResult }),
    });
    expect(firstHuman.status).toBe(200);

    // Same challenge is now 'used', so a second call must be rejected — either because the
    // challenge is no longer 'device_ok', or (if resubmitted against a fresh device_ok row)
    // because the session_nullifier was already stored. This test exercises the challenge-status
    // path, which is the one actually reachable through the real endpoint sequence.
    const secondHuman = await app.request(`/v1/captures/${challengeId}/human`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ result: humanResult }),
    });
    expect(secondHuman.status).toBe(400);
  });

  it("rejects a device submission whose postSignature does not match the commitment", async () => {
    const { profileId, key } = await createProfile("erin");
    const challengeRes = await app.request("/v1/captures/challenge", {
      method: "POST",
      headers: { "x-profile-id": hex(profileId) },
    });
    const { challengeId } = (await challengeRes.json()) as { challengeId: string };

    const imageBytes = Buffer.from("tampered-flow-image", "utf8");
    const assertion = Buffer.from("assertion", "utf8");
    const otherKey = new SoftwareProfileKeyForTests();
    // Sign with a DIFFERENT key than the one whose public key we submit — must be rejected.
    const wrongSig = otherKey.sign(Buffer.from("not the real commitment message"));

    const deviceRes = await app.request(`/v1/captures/${challengeId}/device`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        imageBase64: imageBytes.toString("base64"),
        assertionBase64: assertion.toString("base64"),
        postSignature: hex(wrongSig),
        profilePublicKey: hex(key.publicKeyX963),
      }),
    });
    expect(deviceRes.status).toBe(400);
    const body = await deviceRes.json();
    expect((body as any).error).toBe("post_signature_invalid");
  });
});
