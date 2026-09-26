import { randomBytes } from "node:crypto";
import { hashSignal } from "../../src/proto/captureHasher.js";

/**
 * Builds a hand-built World verify-API response fixture, shaped per docs/ARCHITECTURE.md
 * §03/§12 ("Selfie Check results include sybil_score and an integrity_bundle... signal_hash
 * inside the result... nullifier / session_id / session_nullifier"). Field names beyond what's
 * directly quoted in ARCHITECTURE.md are our best documented understanding, not independently
 * confirmed against a live World sandbox in this session — see docs/WORKLOG.md.
 *
 * Used with PUPILLE_WORLD_API_FIXTURE_MODE=1, which still runs the real signal_hash check
 * (FixtureWorldVerifyClient), so a test submitting a wrong signal fails exactly as it would
 * against the real API.
 */
export function buildWorldProofFixture(opts: {
  signal: string;
  kind: "uniqueness" | "session";
  sessionId?: string;
}) {
  const signalHash = hashSignal(opts.signal);
  const base = {
    success: true,
    signal_hash: signalHash,
    identifier: "11",
    issuer_schema_id: "11",
    sybil_score: 1,
    integrity_bundle: { fixture: true },
  };
  if (opts.kind === "uniqueness") {
    return { ...base, nullifier: BigInt("0x" + randomBytes(20).toString("hex")).toString() };
  }
  return {
    ...base,
    session_id: opts.sessionId ?? `session_${randomBytes(64).toString("hex")}`,
    session_nullifier: BigInt("0x" + randomBytes(20).toString("hex")).toString(),
  };
}
