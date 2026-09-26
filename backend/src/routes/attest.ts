import { Hono } from "hono";
import { createHash, randomBytes } from "node:crypto";
import type pg from "pg";
import { verifyAttestation, AppAttestVerificationError } from "../appattest/verify.js";
import { config } from "../config.js";

const challenges = new Map<string, { challenge: Buffer; expiresAt: number }>();

export function attestRoutes(pool: pg.Pool) {
  const app = new Hono();

  app.post("/status", async (c) => {
    const body = await c.req.json<{ keyId: string }>();
    if (typeof body.keyId !== "string" || body.keyId.length > 512) {
      return c.json({ error: "invalid_key_id" }, 400);
    }
    const existing = await pool.query("select 1 from app_attest_keys where key_id=$1", [body.keyId]);
    return c.json({ registered: Boolean(existing.rowCount) });
  });

  // POST /v1/attest/challenge
  app.post("/challenge", async (c) => {
    const challenge = randomBytes(32);
    const challengeId = randomBytes(16).toString("hex");
    challenges.set(challengeId, { challenge, expiresAt: Date.now() + 5 * 60_000 });
    return c.json({ challengeId, challenge: challenge.toString("hex") });
  });

  // POST /v1/attest/register
  app.post("/register", async (c) => {
    const body = await c.req.json<{ challengeId: string; keyId: string; attestationObject: string }>();
    const pending = challenges.get(body.challengeId);
    if (!pending || pending.expiresAt < Date.now()) {
      return c.json({ error: "challenge_expired" }, 400);
    }
    challenges.delete(body.challengeId);

    if (!body.keyId || !body.attestationObject) {
      return c.json({ error: "attestation_missing_fields" }, 400);
    }

    try {
      const expectedClientDataHash = createHash("sha256").update(pending.challenge).digest();
      const result = await verifyAttestation(
        Buffer.from(body.attestationObject, "base64"),
        expectedClientDataHash,
        config.appId,
        config.appAttestRootCaOverridePem, // undefined in production; only fake-phone/tests set this
        body.keyId
      );
      await pool.query(
        `insert into app_attest_keys (key_id, public_key, receipt, counter) values ($1, $2, $3, $4)
         on conflict (key_id) do nothing`,
        [result.keyId, result.publicKeyX963, result.receiptCbor, result.counter]
      );
      return c.json({ keyId: result.keyId });
    } catch (err) {
      if (err instanceof AppAttestVerificationError) {
        return c.json({ error: err.code }, 400);
      }
      throw err;
    }
  });

  return app;
}
