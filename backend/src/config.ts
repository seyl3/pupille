function required(name: string, fallback?: string): string {
  const value = process.env[name] ?? fallback;
  if (value === undefined) throw new Error(`${name} is required`);
  return value;
}

export const config = {
  rpSigningKeyHex: required("PUPILLE_RP_SIGNING_KEY_HEX", "11".repeat(32)), // dev-only default, 32-byte hex
  rpId: required("PUPILLE_RP_ID", "pupille-dev"),
  worldApiBase: required("PUPILLE_WORLD_API_BASE", "https://developer.worldcoin.org"),
  appId: required("PUPILLE_APP_ID", "test.pupille"),
  // When set, the backend calls this instead of the real World API — used so tests can
  // run against a recorded fixture instead of a live network call. Never set in production.
  worldApiFixtureMode: process.env.PUPILLE_WORLD_API_FIXTURE_MODE === "1",
};
