import { Hono } from "hono";
import { randomBytes } from "node:crypto";
import { ulid } from "ulid";
import { signRequest } from "@worldcoin/idkit-core/signing";
import type pg from "pg";
import {
  imageHash as computeImageHash,
  depthHash as computeDepthHash,
  captureCommitment,
  worldSignal,
  hex,
  hexDecode,
} from "../proto/captureHasher.js";
import { verifyProfileSignature } from "../proto/profileKey.js";
import { postSignatureMessage } from "../proto/captureHasher.js";
import { config } from "../config.js";
import { createWorldVerifyClient, WorldVerifyError, type WorldVerifyResult } from "../world/verifyClient.js";
import { signCertificate } from "../issuer.js";
import { verifyAssertion, AppAttestVerificationError } from "../appattest/verify.js";
import { clientDataHash as computeClientDataHash } from "../proto/captureHasher.js";

export function captureRoutes(pool: pg.Pool) {
  const app = new Hono();
  const worldClient = createWorldVerifyClient();

  // POST /v1/captures/challenge  (auth: session token — simplified to profileId header for this build)
  app.post("/challenge", async (c) => {
    const profileIdHex = c.req.header("x-profile-id");
    if (!profileIdHex) return c.json({ error: "unauthenticated" }, 401);

    const activeKey = await pool.query(
      "select key_version from profile_keys where profile_id = $1 and status = 'active'",
      [hexDecode(profileIdHex)]
    );
    if (activeKey.rowCount === 0) return c.json({ error: "no_active_key" }, 400);

    const attestKeyRow = await pool.query("select app_attest_key_id as key_id from profiles where id = $1", [hexDecode(profileIdHex)]);
    if (attestKeyRow.rowCount === 0) return c.json({ error: "attest_unsupported" }, 400);

    const challenge = randomBytes(32);
    const challengeId = ulid();
    await pool.query(
      `insert into capture_challenges (id, challenge, profile_id, key_version, app_attest_key_id, expires_at)
       values ($1, $2, $3, $4, $5, now() + interval '10 minutes')`,
      [challengeId, challenge, hexDecode(profileIdHex), activeKey.rows[0].key_version, attestKeyRow.rows[0].key_id]
    );
    return c.json({ challengeId, challenge: challenge.toString("hex") });
  });

  // POST /v1/captures/:id/device
  app.post("/:id/device", async (c) => {
    const id = c.req.param("id");
    const body = await c.req.json<{
      imageBase64: string;
      depthBase64?: string;
      assertionBase64: string;
      postSignature: string;
      profilePublicKey: string;
    }>();

    const challengeRow = await pool.query(
      "select * from capture_challenges where id = $1 and status = 'issued' and expires_at > now()",
      [id]
    );
    if (challengeRow.rowCount === 0) return c.json({ error: "challenge_expired" }, 400);
    const row = challengeRow.rows[0];

    const imageBytes = Buffer.from(body.imageBase64, "base64");
    const depthBytes = body.depthBase64 ? Buffer.from(body.depthBase64, "base64") : null;
    const assertion = Buffer.from(body.assertionBase64, "base64");
    const profilePublicKey = hexDecode(body.profilePublicKey);
    const boundKey = await pool.query(
      "select 1 from profile_keys where profile_id=$1 and key_version=$2 and public_key=$3 and status='active'",
      [row.profile_id, row.key_version, profilePublicKey]
    );
    if (!boundKey.rowCount) return c.json({ error: "profile_key_mismatch" }, 400);

    const imgHash = computeImageHash(imageBytes);
    const dHash = computeDepthHash(depthBytes);
    const assertHash = computeImageHash(assertion); // assertionHash == sha256(assertion), same primitive
    const commitment = captureCommitment(imgHash, dHash, row.challenge, assertHash, row.profile_id, profilePublicKey);

    const postSig = hexDecode(body.postSignature);
    if (!verifyProfileSignature(postSig, postSignatureMessage(commitment), profilePublicKey)) {
      return c.json({ error: "post_signature_invalid" }, 400);
    }

    // App Attest assertion check, per docs/ARCHITECTURE.md §08: signature over
    // SHA256(authenticatorData || clientDataHash) under the *stored* App Attest public key
    // (from /attest/register), rpIdHash == SHA256(appId), counter strictly greater than stored.
    const attestKeyRow = await pool.query(
      "select public_key, counter from app_attest_keys where key_id = $1",
      [row.app_attest_key_id]
    );
    if (attestKeyRow.rowCount === 0) {
      return c.json({ error: "app_attest_key_not_found" }, 400);
    }
    const storedPublicKey: Buffer = attestKeyRow.rows[0].public_key;
    const storedCounter: number = attestKeyRow.rows[0].counter;
    const expectedClientDataHash = computeClientDataHash(imgHash, dHash, row.challenge);

    let assertionResult;
    try {
      assertionResult = verifyAssertion(assertion, expectedClientDataHash, config.appId, storedPublicKey, storedCounter);
    } catch (err) {
      if (err instanceof AppAttestVerificationError) {
        return c.json({ error: err.code }, 400);
      }
      throw err;
    }

    await pool.query(
      `update capture_challenges set image_sha256=$1, depth_sha256=$2, assertion_sha256=$3,
         commitment=$4, post_signature=$5, status='device_ok', pending_image=$6, pending_depth=$7 where id=$8`,
      [imgHash, dHash, assertHash, commitment, postSig, imageBytes, depthBytes, id]
    );
    await pool.query("update app_attest_keys set counter = $1 where key_id = $2", [
      assertionResult.counter,
      row.app_attest_key_id,
    ]);

    const rpContext = signRequest({ signingKeyHex: config.rpSigningKeyHex });
    return c.json({ rpContext, worldSignal: worldSignal(commitment) });
  });

  // POST /v1/captures/:id/human
  app.post("/:id/human", async (c) => {
    const id = c.req.param("id");
    const body = await c.req.json<{ result: Record<string, unknown>; caption?: string }>();

    const challengeRow = await pool.query(
      "select * from capture_challenges where id = $1 and status = 'device_ok' and expires_at > now()",
      [id]
    );
    if (challengeRow.rowCount === 0) return c.json({ error: "challenge_not_ready" }, 400);
    const row = challengeRow.rows[0];

    const profile = await pool.query("select * from profiles where id = $1", [row.profile_id]);
    if (profile.rowCount === 0) return c.json({ error: "profile_not_found" }, 400);
    const sessionId: string = profile.rows[0].session_id;

    const expectedSignal = worldSignal(row.commitment);
    let verifyResult: WorldVerifyResult;
    try {
      verifyResult = await worldClient.verify(config.rpId, body.result, expectedSignal);
    } catch (err) {
      if (err instanceof WorldVerifyError) return c.json({ error: err.code }, 400);
      throw err;
    }

    if (verifyResult.session_id !== sessionId) {
      return c.json({ error: "session_mismatch" }, 400);
    }
    if (!verifyResult.session_nullifier) {
      return c.json({ error: "missing_session_nullifier" }, 400);
    }

    const client = await pool.connect();
    try {
      await client.query("BEGIN");

      // Replay protection: unique constraint on (nullifier, action) — "human-session" is the
      // per-post action tag we store the session_nullifier under.
      await client.query(
        `insert into world_session_nullifiers (nullifier, action) values ($1, 'human-session')`,
        [verifyResult.session_nullifier]
      );

      const activeKey = await client.query(
        "select key_version, public_key from profile_keys where profile_id = $1 and status = 'active'",
        [row.profile_id]
      );
      const keyVersion = activeKey.rows[0].key_version;

      const postId = ulid();
      const captionSha256 = body.caption
        ? computeImageHash(Buffer.from(body.caption, "utf8")).toString("hex")
        : null;

      const certJson = {
        v: 1,
        type: "capture",
        issuer: "pupille-backend-1",
        postId,
        appId: config.appId,
        profileId: hex(row.profile_id),
        keyVersion,
        imageSha256: hex(row.image_sha256),
        depthSha256: hex(row.depth_sha256),
        flatness: null,
        captionSha256,
        challenge: hex(row.challenge),
        assertionSha256: hex(row.assertion_sha256),
        captureCommitment: hex(row.commitment),
        challengeIssuedAt: row.issued_at,
        certifiedAt: new Date().toISOString(),
      };
      const certBytes = Buffer.from(JSON.stringify(certJson), "utf8");
      const certSig = signCertificate(certBytes);

      await client.query(
        `insert into posts (id, profile_id, key_version, challenge_id, image, content_type, depth, caption,
           post_signature, capture_cert, capture_cert_sig)
         values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
        [
          postId,
          row.profile_id,
          keyVersion,
          id,
          row.pending_image,
          "image/jpeg",
          row.pending_depth,
          body.caption ?? null,
          row.post_signature,
          certBytes,
          certSig,
        ]
      );
      await client.query("update capture_challenges set status = 'used' where id = $1", [id]);
      await client.query("COMMIT");

      return c.json({ postId, captureCert: { certB64: certBytes.toString("base64"), sigB64: certSig.toString("base64") } });
    } catch (err) {
      await client.query("ROLLBACK");
      if ((err as { code?: string }).code === "23505") {
        return c.json({ error: "session_nullifier_replayed" }, 409);
      }
      throw err;
    } finally {
      client.release();
    }
  });

  // Current native IDKit supports the Proof of Human uniqueness request, but does
  // not expose session proofs. A verified profile may publish with its bound Secure
  // Enclave key and fresh App Attest assertion. The certificate records that no
  // per-post World session proof was obtained.
  app.post("/:id/publish", async (c) => {
    const id = c.req.param("id");
    const body = await c.req.json<{ caption?: string }>();
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      const challenge = await client.query(
        "select * from capture_challenges where id=$1 and status='device_ok' and expires_at>now() for update", [id]
      );
      if (!challenge.rowCount) {
        await client.query("ROLLBACK");
        return c.json({ error: "challenge_not_ready" }, 400);
      }
      const row = challenge.rows[0];
      const profile = await client.query("select credential from profiles where id=$1", [row.profile_id]);
      if (profile.rows[0]?.credential !== "proof_of_human") {
        await client.query("ROLLBACK");
        return c.json({ error: "human_profile_required" }, 400);
      }
      const postId = ulid();
      const caption = body.caption?.slice(0, 500) ?? null;
      const cert = Buffer.from(JSON.stringify({
        v: 1, type: "capture", issuer: "pupille-backend-1", postId,
        appId: config.appId, profileId: hex(row.profile_id), keyVersion: row.key_version,
        imageSha256: hex(row.image_sha256), depthSha256: hex(row.depth_sha256),
        captionSha256: caption ? computeImageHash(Buffer.from(caption, "utf8")).toString("hex") : null,
        challenge: hex(row.challenge), assertionSha256: hex(row.assertion_sha256),
        captureCommitment: hex(row.commitment), challengeIssuedAt: row.issued_at,
        worldSession: false, certifiedAt: new Date().toISOString(),
      }), "utf8");
      const signature = signCertificate(cert);
      await client.query(
        `insert into posts (id, profile_id, key_version, challenge_id, image, content_type, depth, caption,
         post_signature, capture_cert, capture_cert_sig) values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
        [postId, row.profile_id, row.key_version, id, row.pending_image, "image/jpeg", row.pending_depth,
          caption, row.post_signature, cert, signature]
      );
      await client.query("update capture_challenges set status='used', pending_image=null, pending_depth=null where id=$1", [id]);
      await client.query("COMMIT");
      return c.json({ postId });
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  });

  return app;
}
