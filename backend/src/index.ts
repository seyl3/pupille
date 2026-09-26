import { serve } from "@hono/node-server";
import { createApp } from "./app.js";
import { createPool } from "./db/pool.js";

const pool = createPool();
const app = createApp(pool);
const port = Number(process.env.PORT ?? 8787);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`Pupille backend listening on http://localhost:${info.port}`);
});
