import { config } from "../config.js";
import { hashSignal } from "../proto/captureHasher.js";

/**
 * Shape of the World `/api/v4/verify/{rp_id}` response, per docs/ARCHITECTURE.md §03/§12:
 * "Selfie Check results include sybil_score and an integrity_bundle (World App's App Attest
 * attestation)... signal_hash inside the result... identifier and issuer_schema_id on each response."
 * Exact field names beyond what's quoted in ARCHITECTURE.md are NOT independently confirmed
 * against World's live API in this session (no sandbox credentials available) — see
 * docs/WORKLOG.md "Untested". This type is our best-documented understanding, not a verified contract.
 */
export interface WorldVerifyResult {
  success: boolean;
  signal_hash: string;
  nullifier?: string; // present for uniqueness proofs
  session_id?: string; // present for session (createSession/proveSession) proofs
  session_nullifier?: string; // present for session proofs, replay protection
  sybil_score?: number;
  identifier?: string;
  issuer_schema_id?: string;
  integrity_bundle?: unknown;
  [key: string]: unknown;
}

export class WorldVerifyError extends Error {
  constructor(message: string, public code: string) {
    super(message);
  }
}

export interface WorldVerifyClient {
  verify(rpId: string, resultJson: Record<string, unknown>, expectedSignal: string): Promise<WorldVerifyResult>;
}

/**
 * Recomputes signal_hash itself and checks it against the response BEFORE trusting anything else,
 * per §03: "The verify API does not take an expected signal... the RP must compare it itself."
 */
function assertSignalHashMatches(result: WorldVerifyResult, expectedSignal: string) {
  const expectedHash = hashSignal(expectedSignal);
  if (result.signal_hash !== expectedHash) {
    throw new WorldVerifyError(
      `signal_hash mismatch: response had ${result.signal_hash}, expected ${expectedHash}`,
      "signal_hash_mismatch"
    );
  }
}

/** Real client: calls World's live verify API. Never exercised in this session (no network/creds). */
export class HttpWorldVerifyClient implements WorldVerifyClient {
  async verify(rpId: string, resultJson: Record<string, unknown>, expectedSignal: string): Promise<WorldVerifyResult> {
    const response = await fetch(`${config.worldApiBase}/api/v4/verify/${rpId}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(resultJson),
    });
    if (!response.ok) {
      throw new WorldVerifyError(`World verify API returned ${response.status}`, "verify_http_error");
    }
    const result = (await response.json()) as WorldVerifyResult;
    assertSignalHashMatches(result, expectedSignal);
    return result;
  }
}

/**
 * Fixture client for tests: takes the exact "app-submitted" result JSON (built by the test using
 * our own hashSignal, exactly as a real World App response would be shaped per §03/§12) and returns
 * it as if World had verified it — but STILL runs the real assertSignalHashMatches check, so a test
 * that submits a bad signal_hash still fails here exactly as it would against the real API.
 * This never fabricates success for a request whose signal_hash doesn't match.
 */
export class FixtureWorldVerifyClient implements WorldVerifyClient {
  async verify(_rpId: string, resultJson: Record<string, unknown>, expectedSignal: string): Promise<WorldVerifyResult> {
    const result = resultJson as unknown as WorldVerifyResult;
    assertSignalHashMatches(result, expectedSignal);
    if (!result.success) {
      throw new WorldVerifyError("fixture result marked unsuccessful", "verify_failed");
    }
    return result;
  }
}

export function createWorldVerifyClient(): WorldVerifyClient {
  return config.worldApiFixtureMode ? new FixtureWorldVerifyClient() : new HttpWorldVerifyClient();
}
