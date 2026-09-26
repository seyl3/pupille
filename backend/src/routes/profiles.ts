import { Hono } from "hono";
import { randomBytes } from "node:crypto";
import { signRequest } from "@worldcoin/idkit-core/signing";
import type pg from "pg";
import {
  profileCommitment,
  profileSignal,
  profilePoPMessage,
  profileAssertClientDataHash,
  hashSignal,
  hex,
  hexDecode,
} from "../proto/captureHasher.js";
import { verifyProfileSignature } from "../proto/profileKey.js";
import { config } from "../config.js";
import { createWorldVerifyClient, WorldVerifyError, type WorldVerifyResult } from "../world/verifyClient.js";
import { signCertificate } from "../issuer.js";
import { verifyAssertion, AppAttestVerificationError } from "../appattest/verify.js";

const UNIQUENESS_ACTION = "pupille-profile-v1";
const RESERVATION_TTL_MS = 10 * 60_000;

interface StartResponse {
  reservationId: string;
  rpContext: ReturnType<typeof signRequest>;
}

export function profileRoutes(pool: pg.Pool) {
  const app = new Hono();
  const worldClient = createWorldVerifyClient();

  // GET /v1/handles/:h
  app.get("/handles/:handle", async (c) => {
    const handle = c.req.param("handle").toLowerCase();
    if (!/^[a-z0-9_]{3,20}$/.test(handle)) {
      return c.json({ available: false, reason: "invalid_format" });
    }
    const existing = await pool.query("select 1 from profiles where handle = $1", [handle]);
    const reserved = await pool.query(
      "select 1 from profile_sessions where handle = $1 and used = false and expires_at > now()",
      [handle]
    );
    return c.json({ available: existing.rowCount === 0 && reserved.rowCount === 0 });
  });

  // POST /v1/profiles/start
  app.post("/profiles/start", async (c) => {
    const body = await c.req.json<{ profileId: string; publicKey: string; handle: string; attestKeyId: string }>();
    const handle = body.handle.toLowerCase();
    if (!/^[a-z0-9_]{3,20}$/.test(handle)) {
      return c.json({ error: "invalid_handle" }, 400);
    }

    const existing = await pool.query("select handle from profiles where handle = $1", [handle]);
    if (existing.rowCount && existing.rowCount > 0) {
      return c.json({ error: "handle_taken" }, 409);
    }

    const keyRow = await pool.query("select key_id from app_attest_keys where key_id = $1", [body.attestKeyId]);
    if (keyRow.rowCount === 0) {
      return c.json({ error: "attest_unsupported" }, 400);
    }

    const reservationId = randomBytes(16).toString("hex");
    await pool.query(
      `insert into profile_sessions (id, profile_id, public_key, handle, app_attest_key_id, expires_at)
       values ($1, $2, $3, $4, $5, now() + interval '10 minutes')`,
      [reservationId, hexDecode(body.profileId), hexDecode(body.publicKey), handle, body.attestKeyId]
    );

    const rpContext = signRequest({ signingKeyHex: config.rpSigningKeyHex, action: UNIQUENESS_ACTION });
    const response: StartResponse = { reservationId, rpContext };
    return c.json(response);
  });

  // POST /v1/profiles/unique
  app.post("/profiles/unique", async (c) => {
    const body = await c.req.json<{ reservationId: string; result: Record<string, unknown> }>();
    const reservation = await pool.query(
      "select * from profile_sessions where id = $1 and used = false and expires_at > now()",
      [body.reservationId]
    );
    if (reservation.rowCount === 0) {
      return c.json({ error: "reservation_expired" }, 400);
    }
    const row = reservation.rows[0];
    const profileId: Buffer = row.profile_id;
    const publicKey: Buffer = row.public_key;
    const commitment = profileCommitment(profileId, publicKey, row.handle);
    const expectedSignal = profileSignal(commitment);

    let verifyResult: WorldVerifyResult;
    try {
      verifyResult = await worldClient.verify(config.rpId, body.result, expectedSignal);
    } catch (err) {
      if (err instanceof WorldVerifyError) return c.json({ error: err.code }, 400);
      throw err;
    }

    if (!verifyResult.nullifier) {
      return c.json({ error: "missing_nullifier" }, 400);
    }

    const dup = await pool.query("select handle from profiles where nullifier = $1", [verifyResult.nullifier]);
    if (dup.rowCount && dup.rowCount > 0) {
      return c.json({ error: "one_profile_per_human", handle: dup.rows[0].handle }, 409);
    }

    // Claim the nullifier atomically HERE, not just at /complete — otherwise two /unique calls
    // for the same World ID (e.g. a retried request, or a race) could both pass this check before
    // either has inserted into `profiles`. world_session_nullifiers' primary key on
    // (nullifier, action) makes this claim atomic; a duplicate insert throws Postgres 23505.
    try {
      await pool.query(
        `insert into world_session_nullifiers (nullifier, action) values ($1, $2)`,
        [verifyResult.nullifier, UNIQUENESS_ACTION]
      );
    } catch (err) {
      if ((err as { code?: string }).code === "23505") {
        return c.json({ error: "one_profile_per_human" }, 409);
      }
      throw err;
    }

    // Session rpContext (no action), returned so the app can call createSession next.
    const sessionRpContext = signRequest({ signingKeyHex: config.rpSigningKeyHex });
    return c.json({ nullifier: verifyResult.nullifier, sessionRpContext });
  });

  // POST /v1/profiles/complete
  app.post("/profiles/complete", async (c) => {
    const body = await c.req.json<{
      reservationId: string;
      nullifier: string;
      result: Record<string, unknown>;
      profilePoP: string;
      assertionBase64: string;
    }>();

    const reservation = await pool.query(
      "select * from profile_sessions where id = $1 and used = false and expires_at > now()",
      [body.reservationId]
    );
    if (reservation.rowCount === 0) {
      return c.json({ error: "reservation_expired" }, 400);
    }
    const row = reservation.rows[0];
    const profileId: Buffer = row.profile_id;
    const publicKey: Buffer = row.public_key;
    const commitment = profileCommitment(profileId, publicKey, row.handle);
    const expectedSignal = profileSignal(commitment);

    let verifyResult: WorldVerifyResult;
    try {
      verifyResult = await worldClient.verify(config.rpId, body.result, expectedSignal);
    } catch (err) {
      if (err instanceof WorldVerifyError) return c.json({ error: err.code }, 400);
      throw err;
    }
    if (!verifyResult.session_id) {
      return c.json({ error: "missing_session_id" }, 400);
    }

    const popValid = verifyProfileSignature(hexDecode(body.profilePoP), profilePoPMessage(commitment), publicKey);
    if (!popValid) {
      return c.json({ error: "profile_pop_invalid" }, 400);
    }

    // App Attest assertion over H("pupille:profile-assert:v1" || profileCommitment), per §07's
    // backend-checks line — proves the same attested app instance that reserved this handle is
    // the one completing profile creation, using the App Attest key bound to this reservation.
    const attestKeyRow = await pool.query(
      "select public_key, counter from app_attest_keys where key_id = $1",
      [row.app_attest_key_id]
    );
    if (attestKeyRow.rowCount === 0) {
      return c.json({ error: "app_attest_key_not_found" }, 400);
    }
    const storedPublicKey: Buffer = attestKeyRow.rows[0].public_key;
    const storedCounter: number = attestKeyRow.rows[0].counter;
    let profileAssertionResult;
    try {
      profileAssertionResult = verifyAssertion(
        Buffer.from(body.assertionBase64, "base64"),
        profileAssertClientDataHash(commitment),
        config.appId,
        storedPublicKey,
        storedCounter
      );
    } catch (err) {
      if (err instanceof AppAttestVerificationError) return c.json({ error: err.code }, 400);
      throw err;
    }

    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      await client.query(
        `insert into profiles (id, nullifier, session_id, sybil_score, handle, credential, app_attest_key_id)
         values ($1, $2, $3, $4, $5, $6, $7)`,
        [profileId, body.nullifier, verifyResult.session_id, verifyResult.sybil_score ?? null, row.handle, "proof_of_human", row.app_attest_key_id]
      );
      await client.query("update app_attest_keys set counter = $1 where key_id = $2", [
        profileAssertionResult.counter,
        row.app_attest_key_id,
      ]);

      const certJson = {
        v: 1,
        type: "profile",
        issuer: "pupille-backend-1",
        profileId: hex(profileId),
        handle: row.handle,
        keyVersion: 1,
        publicKey: publicKey.toString("base64"),
        credential: "proof_of_human",
        uniquenessAction: UNIQUENESS_ACTION,
        worldSession: true,
        profileCommitment: hex(commitment),
        validFrom: new Date().toISOString(),
      };
      const certBytes = Buffer.from(JSON.stringify(certJson), "utf8");
      const certSig = signCertificate(certBytes);

      await client.query(
        `insert into profile_keys (profile_id, key_version, public_key, status, cert, cert_sig)
         values ($1, 1, $2, 'active', $3, $4)`,
        [profileId, publicKey, certBytes, certSig]
      );
      await client.query("update profile_sessions set used = true where id = $1", [body.reservationId]);
      await client.query("COMMIT");

      return c.json({
        handle: row.handle,
        profileCert: { certB64: certBytes.toString("base64"), sigB64: certSig.toString("base64") },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      throw err;
    } finally {
      client.release();
    }
  });

  // POST /v1/profiles/rotate — new iPhone: proveSession(saved session_id) over a new
  // profileCommitment (same profileId + handle, new key). Per §05: "a proof of the saved session
  // over a new profileCommitment ... activates key version n+1 and retires n. Old posts stay valid."
  app.post("/profiles/rotate", async (c) => {
    const body = await c.req.json<{
      profileId: string;
      newPublicKey: string;
      result: Record<string, unknown>;
      newKeyPoP: string;
    }>();
    const profileId = hexDecode(body.profileId);
    const newPublicKey = hexDecode(body.newPublicKey);

    const profile = await pool.query("select * from profiles where id = $1", [profileId]);
    if (profile.rowCount === 0) return c.json({ error: "profile_not_found" }, 404);
    const handle: string = profile.rows[0].handle;
    const sessionId: string = profile.rows[0].session_id;

    const newCommitment = profileCommitment(profileId, newPublicKey, handle);
    const expectedSignal = profileSignal(newCommitment);

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

    const popValid = verifyProfileSignature(hexDecode(body.newKeyPoP), profilePoPMessage(newCommitment), newPublicKey);
    if (!popValid) {
      return c.json({ error: "profile_pop_invalid" }, 400);
    }

    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      const activeKey = await client.query(
        "select key_version from profile_keys where profile_id = $1 and status = 'active'",
        [profileId]
      );
      if (activeKey.rowCount === 0) throw new Error("no active key found for profile during rotation");
      const nextVersion = activeKey.rows[0].key_version + 1;

      const certJson = {
        v: 1,
        type: "profile",
        issuer: "pupille-backend-1",
        profileId: hex(profileId),
        handle,
        keyVersion: nextVersion,
        publicKey: newPublicKey.toString("base64"),
        credential: "proof_of_human",
        uniquenessAction: UNIQUENESS_ACTION,
        worldSession: true,
        profileCommitment: hex(newCommitment),
        validFrom: new Date().toISOString(),
      };
      const certBytes = Buffer.from(JSON.stringify(certJson), "utf8");
      const certSig = signCertificate(certBytes);

      // Retire the old key BEFORE inserting the new one — the one_active_key partial unique
      // index (on status = 'active') would otherwise reject having two active rows at once.
      await client.query(
        "update profile_keys set status = 'retired', retired_at = now() where profile_id = $1 and status = 'active'",
        [profileId]
      );
      await client.query(
        `insert into profile_keys (profile_id, key_version, public_key, status, cert, cert_sig)
         values ($1, $2, $3, 'active', $4, $5)`,
        [profileId, nextVersion, newPublicKey, certBytes, certSig]
      );
      await client.query("COMMIT");

      return c.json({
        handle,
        keyVersion: nextVersion,
        profileCert: { certB64: certBytes.toString("base64"), sigB64: certSig.toString("base64") },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      throw err;
    } finally {
      client.release();
    }
  });

  return app;
}
