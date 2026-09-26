import pg from "pg";

const { Pool } = pg;

export function createPool(): pg.Pool {
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    throw new Error("DATABASE_URL is required (e.g. postgresql://postgres@/pupille_test?host=/tmp&port=5433)");
  }
  return new Pool({ connectionString });
}
