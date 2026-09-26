import { randomBytes } from "node:crypto";
import { Hono } from "hono";
import type pg from "pg";
import { config } from "../config.js";
import { verifyProfileSignature } from "../proto/profileKey.js";

/** Local staging-only reset. A registered Secure Enclave profile key must authorize it. */
export function demoResetRoutes(pool: pg.Pool) {
  const app = new Hono();
  const enabled = () => config.enableDemoReset && config.worldEnvironment === "staging"
    && process.env.NODE_ENV !== "production";

  app.post("/challenge", async (c) => {
    if (!enabled()) return c.notFound();
    const body = await c.req.json<{ profileId?: string }>();
    if (!/^[0-9a-fA-F]{32}$/.test(body.profileId ?? "")) {
      return c.json({ error: "invalid_profile_id" }, 400);
    }
    const profileId = Buffer.from(body.profileId!, "hex");
    const key = await pool.query(
      "select 1 from profile_keys where profile_id=$1 and status='active'", [profileId]
    );
    if (!key.rowCount) return c.json({ error: "profile_not_found" }, 404);
    const challengeId = randomBytes(16).toString("hex");
    const challenge = randomBytes(32);
    await pool.query(
      `insert into demo_reset_challenges (id, profile_id, challenge, expires_at)
       values ($1,$2,$3,now()+interval '5 minutes')`,
      [challengeId, profileId, challenge]
    );
    return c.json({ challengeId, challenge: challenge.toString("hex") });
  });

  app.post("", async (c) => {
    if (!enabled()) return c.notFound();
    const body = await c.req.json<{ challengeId?: string; signature?: string }>();
    if (!/^[0-9a-f]{32}$/.test(body.challengeId ?? "") ||
        !/^[0-9a-fA-F]{128}$/.test(body.signature ?? "")) {
      return c.json({ error: "invalid_reset_request" }, 400);
    }
    const client = await pool.connect();
    try {
      await client.query("begin");
      const result = await client.query(
        `select ch.profile_id, ch.challenge, pk.public_key
         from demo_reset_challenges ch
         join profile_keys pk on pk.profile_id=ch.profile_id and pk.status='active'
         where ch.id=$1 and ch.used=false and ch.expires_at>now()
         for update of ch`, [body.challengeId]
      );
      if (!result.rowCount) {
        await client.query("rollback");
        return c.json({ error: "reset_challenge_expired" }, 400);
      }
      const row = result.rows[0];
      const message = Buffer.concat([
        Buffer.from("pupille:demo-reset:v1"), row.challenge, row.profile_id,
      ]);
      if (!verifyProfileSignature(Buffer.from(body.signature!, "hex"), message, row.public_key)) {
        await client.query("rollback");
        return c.json({ error: "reset_signature_invalid" }, 403);
      }
      // Keep schema, issuer key, and RP config. Clear every local demo identity,
      // post, reaction, registration, and pending challenge in one transaction.
      await client.query(`truncate table
        post_reactions, reaction_challenges, posts, capture_challenges,
        profile_avatar_challenges, demo_reset_challenges, profile_keys,
        profiles, profile_sessions, world_session_nullifiers, app_attest_keys
        restart identity cascade`);
      await client.query("commit");
      return c.json({ reset: true });
    } catch (error) {
      await client.query("rollback");
      throw error;
    } finally {
      client.release();
    }
  });

  return app;
}
