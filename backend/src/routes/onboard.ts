import { Hono } from "hono";
import { randomBytes } from "node:crypto";
import { signRequest } from "@worldcoin/idkit-core/signing";
import type pg from "pg";
import { config } from "../config.js";
import { createWorldVerifyClient, WorldVerifyError } from "../world/verifyClient.js";
import { verifyAssertion, AppAttestVerificationError } from "../appattest/verify.js";
import { signCertificate } from "../issuer.js";
import { profileCommitment, profileSignal, profilePoPMessage, profileAssertClientDataHash, hex, hexDecode } from "../proto/captureHasher.js";
import { verifyProfileSignature } from "../proto/profileKey.js";

const action = "pupille-profile-v1";

/** A Proof of Human profile flow that works with the current native Swift IDKit SDK. */
export function onboardRoutes(pool: pg.Pool) {
  const app = new Hono();
  const world = createWorldVerifyClient();

  app.post("/start", async (c) => {
    const body = await c.req.json<{ profileId: string; publicKey: string; handle: string; attestKeyId: string }>();
    const handle = body.handle?.toLowerCase();
    if (!handle || !/^[a-z0-9_]{3,20}$/.test(handle)) return c.json({ error: "invalid_handle" }, 400);
    if (!/^[0-9a-fA-F]{32}$/.test(body.profileId ?? "") || !/^04[0-9a-fA-F]{128}$/.test(body.publicKey ?? "")) {
      return c.json({ error: "invalid_profile_key" }, 400);
    }
    const key = await pool.query("select 1 from app_attest_keys where key_id = $1", [body.attestKeyId]);
    if (!key.rowCount) return c.json({ error: "attest_key_not_registered" }, 400);
    const exists = await pool.query("select 1 from profiles where handle = $1", [handle]);
    if (exists.rowCount) return c.json({ error: "handle_taken" }, 409);

    const profileId = hexDecode(body.profileId);
    const publicKey = hexDecode(body.publicKey);
    const commitment = profileCommitment(profileId, publicKey, handle);
    const rpContext = signRequest({ signingKeyHex: config.rpSigningKeyHex, action });
    const reservationId = randomBytes(16).toString("hex");
    await pool.query(
      `insert into profile_sessions (id, profile_id, public_key, handle, app_attest_key_id, world_nonce, expires_at)
       values ($1, $2, $3, $4, $5, $6, now() + interval '10 minutes')`,
      [reservationId, profileId, publicKey, handle, body.attestKeyId, rpContext.nonce]
    );
    return c.json({ reservationId, rpContext, worldSignal: profileSignal(commitment), environment: config.worldEnvironment });
  });

  // Check the physical device before requesting a one-time World proof. A device
  // error can then be retried without consuming a simulator or production proof.
  app.post("/device", async (c) => {
    const body = await c.req.json<{ reservationId: string; profilePoP: string; assertionBase64: string }>();
    const pending = await pool.query(
      "select * from profile_sessions where id=$1 and used=false and expires_at>now()", [body.reservationId]
    );
    if (!pending.rowCount) return c.json({ error: "reservation_expired" }, 400);
    const row = pending.rows[0];
    const commitment = profileCommitment(row.profile_id, row.public_key, row.handle);
    try {
      if (!verifyProfileSignature(hexDecode(body.profilePoP), profilePoPMessage(commitment), row.public_key)) {
        return c.json({ error: "profile_pop_invalid" }, 400);
      }
    } catch {
      return c.json({ error: "profile_pop_invalid" }, 400);
    }
    const attestKey = await pool.query("select public_key, counter from app_attest_keys where key_id=$1", [row.app_attest_key_id]);
    if (!attestKey.rowCount) return c.json({ error: "app_attest_key_not_found" }, 400);
    try {
      const checked = verifyAssertion(Buffer.from(body.assertionBase64, "base64"),
        profileAssertClientDataHash(commitment), config.appId,
        attestKey.rows[0].public_key, attestKey.rows[0].counter);
      await pool.query("update profile_sessions set device_verified=true, device_counter=$1 where id=$2",
        [checked.counter, body.reservationId]);
      return c.json({ deviceVerified: true });
    } catch (error) {
      if (error instanceof AppAttestVerificationError) return c.json({ error: error.code }, 400);
      throw error;
    }
  });

  app.post("/complete", async (c) => {
    const body = await c.req.json<{
      reservationId: string; result: Record<string, unknown>; profilePoP?: string; assertionBase64?: string;
    }>();
    const pending = await pool.query(
      "select * from profile_sessions where id = $1 and used = false and expires_at > now()",
      [body.reservationId]
    );
    if (!pending.rowCount) return c.json({ error: "reservation_expired" }, 400);
    const row = pending.rows[0];
    if (body.result?.action !== action || body.result?.nonce !== row.world_nonce) {
      return c.json({ error: "world_request_mismatch" }, 400);
    }
    const commitment = profileCommitment(row.profile_id, row.public_key, row.handle);
    const signal = profileSignal(commitment);
    let verified;
    try {
      verified = await world.verify(config.rpId, body.result, signal);
    } catch (error) {
      if (error instanceof WorldVerifyError) return c.json({ error: error.code }, 400);
      throw error;
    }
    if (!verified.nullifier) return c.json({ error: "missing_nullifier" }, 400);
    const attestKey = await pool.query("select public_key, counter from app_attest_keys where key_id = $1", [row.app_attest_key_id]);
    if (!attestKey.rowCount) return c.json({ error: "app_attest_key_not_found" }, 400);
    let assertion;
    if (row.device_verified && BigInt(row.device_counter) > BigInt(attestKey.rows[0].counter)) {
      assertion = { counter: Number(row.device_counter) };
    } else {
      try {
        if (!body.profilePoP || !body.assertionBase64 ||
          !verifyProfileSignature(hexDecode(body.profilePoP), profilePoPMessage(commitment), row.public_key)) {
          return c.json({ error: "profile_pop_invalid" }, 400);
        }
        assertion = verifyAssertion(Buffer.from(body.assertionBase64, "base64"),
          profileAssertClientDataHash(commitment), config.appId,
          attestKey.rows[0].public_key, attestKey.rows[0].counter);
      } catch (error) {
        if (error instanceof AppAttestVerificationError) return c.json({ error: error.code }, 400);
        return c.json({ error: "profile_pop_invalid" }, 400);
      }
    }

    const cert = Buffer.from(JSON.stringify({
      v: 1, type: "profile", issuer: "pupille-backend-1", profileId: hex(row.profile_id),
      handle: row.handle, keyVersion: 1, publicKey: row.public_key.toString("base64"),
      credential: "proof_of_human", environment: config.worldEnvironment,
      uniquenessAction: action, worldSession: false, profileCommitment: hex(commitment),
      validFrom: new Date().toISOString(),
    }), "utf8");
    const certSig = signCertificate(cert);
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      const locked = await client.query("select used from profile_sessions where id=$1 for update", [body.reservationId]);
      if (locked.rows[0]?.used) {
        await client.query("ROLLBACK");
        return c.json({ error: "reservation_used" }, 409);
      }
      await client.query("insert into world_session_nullifiers (nullifier, action) values ($1, $2)", [verified.nullifier, action]);
      await client.query(
        `insert into profiles (id, nullifier, session_id, handle, credential, app_attest_key_id)
         values ($1, $2, null, $3, $4, $5)`,
        [row.profile_id, verified.nullifier, row.handle, "proof_of_human", row.app_attest_key_id]
      );
      await client.query(
        "insert into profile_keys (profile_id, key_version, public_key, status, cert, cert_sig) values ($1, 1, $2, 'active', $3, $4)",
        [row.profile_id, row.public_key, cert, certSig]
      );
      await client.query("update app_attest_keys set counter=$1 where key_id=$2", [assertion.counter, row.app_attest_key_id]);
      await client.query("update profile_sessions set used=true where id=$1", [body.reservationId]);
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      if ((error as {code?: string}).code === "23505") return c.json({ error: "human_or_handle_already_registered" }, 409);
      throw error;
    } finally {
      client.release();
    }
    return c.json({ handle: row.handle, profileId: hex(row.profile_id), profileCert: {
      certB64: cert.toString("base64"), sigB64: certSig.toString("base64")
    } });
  });
  return app;
}
