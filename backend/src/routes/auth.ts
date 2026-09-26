import { Hono } from "hono";
import { randomBytes, createHmac, timingSafeEqual } from "node:crypto";
import type pg from "pg";
import { authSignatureMessage, hexDecode } from "../proto/captureHasher.js";
import { verifyProfileSignature } from "../proto/profileKey.js";

const authChallenges = new Map<string, { profileId: Buffer; expiresAt: number }>();
const SESSION_SECRET = process.env.PUPILLE_SESSION_SECRET ?? "dev-only-session-secret-do-not-use-in-prod";

function issueToken(profileId: Buffer): string {
  const payload = `${profileId.toString("hex")}.${Date.now() + 24 * 3600_000}`;
  const mac = createHmac("sha256", SESSION_SECRET).update(payload).digest("hex");
  return Buffer.from(`${payload}.${mac}`).toString("base64url");
}

export function verifyToken(token: string): Buffer | null {
  try {
    const decoded = Buffer.from(token, "base64url").toString("utf8");
    const [profileIdHex, expiresAtStr, mac] = decoded.split(".");
    const payload = `${profileIdHex}.${expiresAtStr}`;
    const expectedMac = createHmac("sha256", SESSION_SECRET).update(payload).digest("hex");
    if (!timingSafeEqual(Buffer.from(mac, "hex"), Buffer.from(expectedMac, "hex"))) return null;
    if (Number(expiresAtStr) < Date.now()) return null;
    return hexDecode(profileIdHex);
  } catch {
    return null;
  }
}

export function authRoutes(pool: pg.Pool) {
  const app = new Hono();

  // POST /v1/auth/challenge
  app.post("/challenge", async (c) => {
    const body = await c.req.json<{ profileId: string }>();
    const profileId = hexDecode(body.profileId);
    const profile = await pool.query("select 1 from profiles where id = $1", [profileId]);
    if (profile.rowCount === 0) return c.json({ error: "profile_not_found" }, 404);

    const challenge = randomBytes(32);
    const challengeId = randomBytes(16).toString("hex");
    authChallenges.set(challengeId, { profileId, expiresAt: Date.now() + 5 * 60_000 });
    return c.json({ challengeId, challenge: challenge.toString("hex") });
  });

  // POST /v1/auth/token
  app.post("/token", async (c) => {
    const body = await c.req.json<{ challengeId: string; challenge: string; signature: string }>();
    const pending = authChallenges.get(body.challengeId);
    if (!pending || pending.expiresAt < Date.now()) return c.json({ error: "challenge_expired" }, 400);
    authChallenges.delete(body.challengeId);

    const keyRow = await pool.query(
      "select public_key from profile_keys where profile_id = $1 and status = 'active'",
      [pending.profileId]
    );
    if (keyRow.rowCount === 0) return c.json({ error: "no_active_key" }, 400);

    const challenge = hexDecode(body.challenge);
    const signature = hexDecode(body.signature);
    const valid = verifyProfileSignature(signature, authSignatureMessage(challenge), keyRow.rows[0].public_key);
    if (!valid) return c.json({ error: "signature_invalid" }, 401);

    return c.json({ token: issueToken(pending.profileId) });
  });

  return app;
}
