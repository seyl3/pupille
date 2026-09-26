function required(name: string, fallback?: string): string {
  const value = process.env[name] ?? fallback;
  if (value === undefined) throw new Error(`${name} is required`);
  return value;
}

export const config = {
  rpSigningKeyHex: required("PUPILLE_RP_SIGNING_KEY_HEX", "11".repeat(32)), // dev-only default, 32-byte hex
  rpId: required("PUPILLE_RP_ID", "pupille-dev"),
  worldApiBase: required("PUPILLE_WORLD_API_BASE", "https://developer.world.org"),
  worldEnvironment: required("PUPILLE_WORLD_ENVIRONMENT", "production") as "production" | "staging",
  enableDemoReset: process.env.PUPILLE_ENABLE_DEMO_RESET === "1",
  worldStagingVerificationToken: process.env.PUPILLE_WORLD_STAGING_VERIFICATION_TOKEN ?? "",
  appId: required("PUPILLE_APP_ID", "test.pupille"),
  // When set, the backend calls this instead of the real World API — used so tests can
  // run against a recorded fixture instead of a live network call. Never set in production.
  worldApiFixtureMode: process.env.PUPILLE_WORLD_API_FIXTURE_MODE === "1",
  // When set, App Attest verification trusts this PEM instead of Apple's pinned root —
  // used ONLY by tools/fake-phone and backend tests, which sign fixtures with a throwaway
  // test CA since there is no physical iPhone to produce a real Apple-issued certificate.
  // Must never be set outside a dev/test environment: it defeats the entire point of pinning.
  appAttestRootCaOverridePem: process.env.PUPILLE_APP_ATTEST_TEST_ROOT_PEM,
};

if (process.env.NODE_ENV === "production") {
  if (!process.env.PUPILLE_RP_SIGNING_KEY_HEX || !process.env.PUPILLE_RP_ID || !process.env.PUPILLE_APP_ID) {
    throw new Error("Production requires the World RP signing key, RP ID, and Apple app ID");
  }
  if (config.worldApiFixtureMode || config.appAttestRootCaOverridePem || config.enableDemoReset) {
    throw new Error("Fixture World verification and test App Attest roots are forbidden in production");
  }
}
