import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type pg from "pg";
import { createApp } from "../src/app.js";
import { config } from "../src/config.js";
import { makeTestPool, truncateAll } from "./testDb.js";
import { SoftwareProfileKeyForTests } from "./fixtures/softwareKey.js";

let pool: pg.Pool;
let app: ReturnType<typeof createApp>;
const originalReset = config.enableDemoReset;
const originalEnvironment = config.worldEnvironment;

beforeAll(async () => {
  config.enableDemoReset = true;
  config.worldEnvironment = "staging";
  pool = await makeTestPool();
  app = createApp(pool);
});
beforeEach(async () => { await truncateAll(pool); });
afterAll(async () => {
  config.enableDemoReset = originalReset;
  config.worldEnvironment = originalEnvironment;
  await pool.end();
});

async function request(path: string, body: object) {
  return app.request(path, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("staging demo reset", () => {
  it("requires the active profile key, clears demo records, and cannot replay", async () => {
    const profileId = Buffer.alloc(16, 7);
    const key = new SoftwareProfileKeyForTests();
    await pool.query(
      "insert into profiles (id, nullifier, handle, credential) values ($1, 123, 'demo_user', 'proof_of_human')",
      [profileId]
    );
    await pool.query(
      `insert into profile_keys (profile_id, key_version, public_key, cert, cert_sig)
       values ($1, 1, $2, $3, $4)`, [profileId, key.publicKeyX963, Buffer.from("cert"), Buffer.from("sig")]
    );
    await pool.query("insert into world_session_nullifiers (nullifier, action) values (123, 'pupille-profile-v1')");
    const challengeResponse = await request("/v1/dev/reset/challenge", { profileId: profileId.toString("hex") });
    expect(challengeResponse.status).toBe(200);
    const { challengeId, challenge } = await challengeResponse.json() as { challengeId: string; challenge: string };
    const message = Buffer.concat([
      Buffer.from("pupille:demo-reset:v1"), Buffer.from(challenge, "hex"), profileId,
    ]);
    const wrongKey = new SoftwareProfileKeyForTests();
    expect((await request("/v1/dev/reset", {
      challengeId, signature: wrongKey.sign(message).toString("hex"),
    })).status).toBe(403);
    expect((await pool.query("select count(*)::int as count from profiles")).rows[0].count).toBe(1);
    const accepted = await request("/v1/dev/reset", {
      challengeId, signature: key.sign(message).toString("hex"),
    });
    expect(accepted.status).toBe(200);
    expect(await accepted.json()).toEqual({ reset: true });
    for (const table of ["profiles", "profile_keys", "world_session_nullifiers", "demo_reset_challenges"]) {
      expect((await pool.query(`select count(*)::int as count from ${table}`)).rows[0].count).toBe(0);
    }
    expect((await request("/v1/dev/reset", {
      challengeId, signature: key.sign(message).toString("hex"),
    })).status).toBe(400);
  });

  it("is unavailable outside staging or when disabled", async () => {
    config.worldEnvironment = "production";
    expect((await request("/v1/dev/reset/challenge", { profileId: "00".repeat(16) })).status).toBe(404);
    config.worldEnvironment = "staging";
    config.enableDemoReset = false;
    expect((await request("/v1/dev/reset/challenge", { profileId: "00".repeat(16) })).status).toBe(404);
    config.enableDemoReset = true;
  });
});
