import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createPool } from "./pool.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function main() {
  const pool = createPool();
  const sql = readFileSync(path.join(__dirname, "schema.sql"), "utf8");
  await pool.query(sql);
  await pool.end();
  console.log("migration applied");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
