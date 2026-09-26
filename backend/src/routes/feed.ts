import { Hono } from "hono";
import { randomBytes, createHash } from "node:crypto";
import type pg from "pg";
import { hex } from "../proto/captureHasher.js";
import { verifyProfileSignature } from "../proto/profileKey.js";
import { verifyAssertion, AppAttestVerificationError } from "../appattest/verify.js";
import { config } from "../config.js";

const reactionKinds = ["nerd", "heart", "aubergine", "japan"] as const;
type ReactionKind = (typeof reactionKinds)[number];

export function feedRoutes(pool: pg.Pool) {
  const app = new Hono();

  // GET /v1/feed
  app.get("/feed", async (c) => {
    const result = await pool.query(`
      select p.id, p.caption, p.post_signature, p.capture_cert, p.capture_cert_sig, p.created_at,
             pr.handle, pr.id as profile_id, pr.avatar_image is not null as has_avatar, pk.public_key,
             pk2.cert as profile_cert, pk2.cert_sig as profile_cert_sig
      from posts p
      join profile_keys pk on pk.profile_id = p.profile_id and pk.key_version = p.key_version
      join profiles pr on pr.id = p.profile_id
      join profile_keys pk2 on pk2.profile_id = p.profile_id and pk2.key_version = p.key_version
      order by p.created_at desc
    `);
    const reactionRows = await pool.query(
      "select post_id, reaction, count(*)::int as count from post_reactions group by post_id, reaction"
    );
    const counts = new Map<string, Record<ReactionKind, number>>();
    for (const row of reactionRows.rows) {
      const value = counts.get(row.post_id) ?? { nerd: 0, heart: 0, aubergine: 0, japan: 0 };
      value[row.reaction as ReactionKind] = row.count;
      counts.set(row.post_id, value);
    }
    const viewer = c.req.header("x-profile-id");
    const mine = new Map<string, ReactionKind>();
    if (viewer && /^[0-9a-fA-F]{32}$/.test(viewer)) {
      const ownRows = await pool.query(
        "select post_id, reaction from post_reactions where profile_id=$1", [Buffer.from(viewer, "hex")]
      );
      for (const row of ownRows.rows) mine.set(row.post_id, row.reaction);
    }
    const posts = result.rows.map((row) => ({
      id: row.id,
      imageUrl: `/v1/posts/${row.id}/image`,
      caption: row.caption,
      author: {
        handle: row.handle, profileId: hex(row.profile_id), publicKey: row.public_key.toString("base64"),
        avatarUrl: row.has_avatar ? `/v1/profiles/${row.handle}/avatar` : null,
      },
      postSignature: row.post_signature.toString("base64"),
      profileCert: { certB64: row.profile_cert.toString("base64"), sigB64: row.profile_cert_sig.toString("base64") },
      captureCert: { certB64: row.capture_cert.toString("base64"), sigB64: row.capture_cert_sig.toString("base64") },
      depthUrl: null,
      reactions: counts.get(row.id) ?? { nerd: 0, heart: 0, aubergine: 0, japan: 0 },
      myReaction: mine.get(row.id) ?? null,
      createdAt: row.created_at,
    }));
    return c.json(posts);
  });

  // GET /v1/posts/:id/image
  app.get("/posts/:id/image", async (c) => {
    const row = await pool.query("select image, content_type from posts where id = $1", [c.req.param("id")]);
    if (row.rowCount === 0) return c.notFound();
    c.header("content-type", row.rows[0].content_type);
    return c.body(row.rows[0].image);
  });

  app.post("/posts/:id/reaction/challenge", async (c) => {
    const body = await c.req.json<{ profileId?: string }>();
    if (!/^[0-9a-fA-F]{32}$/.test(body.profileId ?? "")) return c.json({ error: "invalid_profile_id" }, 400);
    const profileId = Buffer.from(body.profileId!, "hex");
    const owner = await pool.query(
      "select 1 from profiles where id=$1 and app_attest_key_id is not null", [profileId]
    );
    if (!owner.rowCount) return c.json({ error: "profile_not_found" }, 404);
    const postId = c.req.param("id");
    const post = await pool.query("select 1 from posts where id=$1", [postId]);
    if (!post.rowCount) return c.notFound();
    const challengeId = randomBytes(16).toString("hex");
    const challenge = randomBytes(32);
    await pool.query(
      `insert into reaction_challenges (id, post_id, profile_id, challenge, expires_at)
       values ($1,$2,$3,$4,now()+interval '5 minutes')`,
      [challengeId, postId, profileId, challenge]
    );
    return c.json({ challengeId, challenge: challenge.toString("hex") });
  });

  app.post("/posts/:id/reaction", async (c) => {
    const body = await c.req.json<{ challengeId?: string; reaction?: string; assertionBase64?: string }>();
    if (!/^[0-9a-f]{32}$/.test(body.challengeId ?? "") ||
        !reactionKinds.includes(body.reaction as ReactionKind) || !body.assertionBase64) {
      return c.json({ error: "invalid_reaction" }, 400);
    }
    const assertion = Buffer.from(body.assertionBase64, "base64");
    if (!assertion.length || assertion.length > 8_000) return c.json({ error: "invalid_assertion" }, 400);
    const postId = c.req.param("id");
    const client = await pool.connect();
    try {
      await client.query("begin");
      const challenge = await client.query(
        `select ch.profile_id, ch.challenge, pr.app_attest_key_id
         from reaction_challenges ch join profiles pr on pr.id=ch.profile_id
         where ch.id=$1 and ch.post_id=$2 and ch.used=false and ch.expires_at>now()
         for update of ch`, [body.challengeId, postId]
      );
      if (!challenge.rowCount) {
        await client.query("rollback");
        return c.json({ error: "reaction_challenge_expired" }, 400);
      }
      const row = challenge.rows[0];
      const key = await client.query(
        "select public_key, counter from app_attest_keys where key_id=$1 for update",
        [row.app_attest_key_id]
      );
      if (!key.rowCount) {
        await client.query("rollback");
        return c.json({ error: "app_attest_key_not_found" }, 400);
      }
      const clientHash = createHash("sha256").update(Buffer.concat([
        Buffer.from("pupille:reaction:v1"), Buffer.from(postId), Buffer.from(body.reaction!), row.challenge,
      ])).digest();
      try {
        const verified = verifyAssertion(assertion, clientHash, config.appId,
          key.rows[0].public_key, key.rows[0].counter);
        await client.query("update app_attest_keys set counter=$1 where key_id=$2",
          [verified.counter, row.app_attest_key_id]);
      } catch (error) {
        if (error instanceof AppAttestVerificationError) {
          await client.query("rollback");
          return c.json({ error: error.code }, 400);
        }
        throw error;
      }
      await client.query(
        `insert into post_reactions (post_id, profile_id, reaction) values ($1,$2,$3)
         on conflict (post_id, profile_id) do update set reaction=excluded.reaction, updated_at=now()`,
        [postId, row.profile_id, body.reaction]
      );
      await client.query("update reaction_challenges set used=true where id=$1", [body.challengeId]);
      await client.query("commit");
      const tally = await pool.query(
        "select reaction, count(*)::int as count from post_reactions where post_id=$1 group by reaction", [postId]
      );
      const reactions: Record<ReactionKind, number> = { nerd: 0, heart: 0, aubergine: 0, japan: 0 };
      for (const entry of tally.rows) reactions[entry.reaction as ReactionKind] = entry.count;
      return c.json({ reactions, myReaction: body.reaction });
    } catch (error) {
      await client.query("rollback");
      throw error;
    } finally { client.release(); }
  });

  // A one-time challenge makes an avatar replacement valid only for the owner
  // of the active Secure Enclave profile key, and prevents replaying old photos.
  app.post("/profiles/avatar/challenge", async (c) => {
    const body = await c.req.json<{ profileId?: string }>();
    if (!/^[0-9a-fA-F]{32}$/.test(body.profileId ?? "")) return c.json({ error: "invalid_profile_id" }, 400);
    const profileId = Buffer.from(body.profileId!, "hex");
    const owner = await pool.query(
      "select 1 from profile_keys where profile_id=$1 and status='active'", [profileId]
    );
    if (!owner.rowCount) return c.json({ error: "profile_not_found" }, 404);
    const id = randomBytes(16).toString("hex");
    const challenge = randomBytes(32);
    await pool.query(
      "insert into profile_avatar_challenges (id, profile_id, challenge, expires_at) values ($1,$2,$3,now()+interval '10 minutes')",
      [id, profileId, challenge]
    );
    return c.json({ challengeId: id, challenge: challenge.toString("hex") });
  });

  app.post("/profiles/avatar", async (c) => {
    const body = await c.req.json<{ challengeId?: string; imageBase64?: string; signature?: string }>();
    if (!/^[0-9a-f]{32}$/.test(body.challengeId ?? "") ||
        !/^[0-9a-fA-F]{128}$/.test(body.signature ?? "") ||
        !body.imageBase64 || body.imageBase64.length > 2_800_000) {
      return c.json({ error: "invalid_avatar_request" }, 400);
    }
    const image = Buffer.from(body.imageBase64, "base64");
    if (image.length === 0 || image.length > 2_000_000 ||
        image[0] !== 0xff || image[1] !== 0xd8 || image[image.length - 2] !== 0xff || image[image.length - 1] !== 0xd9) {
      return c.json({ error: "avatar_must_be_jpeg" }, 400);
    }
    const client = await pool.connect();
    try {
      await client.query("begin");
      const row = await client.query(
        `select ch.profile_id, ch.challenge, pk.public_key
         from profile_avatar_challenges ch
         join profile_keys pk on pk.profile_id=ch.profile_id and pk.status='active'
         where ch.id=$1 and ch.used=false and ch.expires_at>now() for update of ch`,
        [body.challengeId]
      );
      if (!row.rowCount) {
        await client.query("rollback");
        return c.json({ error: "avatar_challenge_expired" }, 400);
      }
      const profileId: Buffer = row.rows[0].profile_id;
      const message = Buffer.concat([
        Buffer.from("pupille:avatar:v1"), row.rows[0].challenge,
        createHash("sha256").update(image).digest(), profileId,
      ]);
      if (!verifyProfileSignature(Buffer.from(body.signature!, "hex"), message, row.rows[0].public_key)) {
        await client.query("rollback");
        return c.json({ error: "avatar_signature_invalid" }, 400);
      }
      await client.query(
        "update profiles set avatar_image=$1, avatar_content_type='image/jpeg', avatar_updated_at=now() where id=$2",
        [image, profileId]
      );
      await client.query("update profile_avatar_challenges set used=true where id=$1", [body.challengeId]);
      await client.query("commit");
      return c.json({ avatarUrl: `/v1/profiles/${hex(profileId)}/avatar` });
    } catch (error) {
      await client.query("rollback");
      throw error;
    } finally { client.release(); }
  });

  app.get("/profiles/:handle/avatar", async (c) => {
    const handle = c.req.param("handle").toLowerCase();
    const profile = await pool.query(
      "select avatar_image, avatar_content_type from profiles where handle=$1 or encode(id, 'hex')=$1 limit 1", [handle]
    );
    if (!profile.rowCount || !profile.rows[0].avatar_image) return c.notFound();
    c.header("content-type", profile.rows[0].avatar_content_type);
    c.header("cache-control", "no-store");
    return c.body(profile.rows[0].avatar_image);
  });

  // GET /v1/profiles/:handle
  app.get("/profiles/:handle", async (c) => {
    const handle = c.req.param("handle").toLowerCase();
    const profile = await pool.query("select * from profiles where handle = $1", [handle]);
    if (profile.rowCount === 0) return c.notFound();
    const keys = await pool.query(
      "select key_version, cert, cert_sig from profile_keys where profile_id = $1 order by key_version",
      [profile.rows[0].id]
    );
    const posts = await pool.query("select id from posts where profile_id = $1 order by created_at desc", [
      profile.rows[0].id,
    ]);
    return c.json({
      handle,
      avatarUrl: profile.rows[0].avatar_image ? `/v1/profiles/${handle}/avatar` : null,
      postCount: posts.rowCount ?? 0,
      joinedAt: profile.rows[0].created_at,
      certs: keys.rows.map((k) => ({
        keyVersion: k.key_version,
        certB64: k.cert.toString("base64"),
        sigB64: k.cert_sig.toString("base64"),
      })),
      postIds: posts.rows.map((p) => p.id),
    });
  });

  return app;
}
