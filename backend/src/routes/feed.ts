import { Hono } from "hono";
import type pg from "pg";
import { hex } from "../proto/captureHasher.js";

export function feedRoutes(pool: pg.Pool) {
  const app = new Hono();

  // GET /v1/feed
  app.get("/feed", async (c) => {
    const result = await pool.query(`
      select p.id, p.caption, p.post_signature, p.capture_cert, p.capture_cert_sig, p.created_at,
             pr.handle, pr.id as profile_id, pk.public_key,
             pk2.cert as profile_cert, pk2.cert_sig as profile_cert_sig
      from posts p
      join profile_keys pk on pk.profile_id = p.profile_id and pk.key_version = p.key_version
      join profiles pr on pr.id = p.profile_id
      join profile_keys pk2 on pk2.profile_id = p.profile_id and pk2.key_version = p.key_version
      order by p.created_at desc
    `);
    const posts = result.rows.map((row) => ({
      id: row.id,
      imageUrl: `/v1/posts/${row.id}/image`,
      caption: row.caption,
      author: { handle: row.handle, profileId: hex(row.profile_id), publicKey: row.public_key.toString("base64") },
      postSignature: row.post_signature.toString("base64"),
      profileCert: { certB64: row.profile_cert.toString("base64"), sigB64: row.profile_cert_sig.toString("base64") },
      captureCert: { certB64: row.capture_cert.toString("base64"), sigB64: row.capture_cert_sig.toString("base64") },
      depthUrl: null,
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
