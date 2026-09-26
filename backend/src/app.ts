import { Hono } from "hono";
import type pg from "pg";
import { attestRoutes } from "./routes/attest.js";
import { profileRoutes } from "./routes/profiles.js";
import { captureRoutes } from "./routes/captures.js";
import { feedRoutes } from "./routes/feed.js";
import { authRoutes } from "./routes/auth.js";
import { issuerPublicKeyDer } from "./issuer.js";

export function createApp(pool: pg.Pool) {
  const app = new Hono();
  const v1 = new Hono();

  v1.route("/attest", attestRoutes(pool));
  v1.route("/", profileRoutes(pool)); // /handles/:h, /profiles/*
  v1.route("/captures", captureRoutes(pool));
  v1.route("/", feedRoutes(pool)); // /feed, /posts/:id/image, /profiles/:handle
  v1.route("/auth", authRoutes(pool));

  v1.get("/issuer-public-key", (c) => c.json({ publicKeyDerBase64: issuerPublicKeyDer().toString("base64") }));

  app.route("/v1", v1);
  app.get("/healthz", (c) => c.json({ ok: true }));

  return app;
}
