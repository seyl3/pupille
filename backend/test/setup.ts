import "reflect-metadata";

// Must be set before any test file imports src/config.ts (which reads it once, at module load
// time) — vitest's setupFiles run before test file imports, so this is the correct place, not
// inside a test file's own top-level statements (those run after ESM import hoisting).
process.env.PUPILLE_WORLD_API_FIXTURE_MODE = "1";
