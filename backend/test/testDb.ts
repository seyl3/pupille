import pg from "pg";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/**
 * Real Postgres for tests — per docs/AGENT_TASK.md 5B, the database is never mocked.
 * Requires DATABASE_URL to point at a real (throwaway) database; the schema is
 * re-applied and all tables truncated before each test file that uses this.
 */
export async function makeTestPool(): Promise<pg.Pool> {
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    throw new Error(
      "DATABASE_URL is required to run backend tests against a real Postgres instance (see docs/WORKLOG.md for how one is started on this machine without sudo)."
    );
  }
  const pool = new pg.Pool({ connectionString });
  const schema = readFileSync(path.join(__dirname, "../src/db/schema.sql"), "utf8");
  await pool.query(schema);
  return pool;
}

export async function truncateAll(pool: pg.Pool) {
  await pool.query(`
    truncate table posts, capture_challenges, app_attest_keys, world_session_nullifiers,
      profile_sessions, profile_keys, profiles restart identity cascade
  `);
}
