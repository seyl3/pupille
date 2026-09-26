import { config } from "../config.js";
import { hashSignal } from "../proto/captureHasher.js";

/** Normalized fields after World accepts an unchanged IDKit 4.0 result. */
export interface WorldVerifyResult {
  success: boolean;
  signal_hash: string; // copied from the verified IDKit response, not /verify's top level
  nullifier?: string; // present for uniqueness proofs
  session_id?: string; // present for session (createSession/proveSession) proofs
  session_nullifier?: string; // present for session proofs, replay protection
  sybil_score?: number;
  identifier?: string;
  issuer_schema_id?: string | number;
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
function assertSignalHashMatches(result: { signal_hash: string }, expectedSignal: string) {
  const expectedHash = hashSignal(expectedSignal);
  if (result.signal_hash.toLowerCase() !== expectedHash.toLowerCase()) {
    throw new WorldVerifyError(
      `signal_hash mismatch: response had ${result.signal_hash}, expected ${expectedHash}`,
      "signal_hash_mismatch"
    );
  }
}

function proofResponse(resultJson: Record<string, unknown>): Record<string, unknown> {
  if (resultJson.protocol_version !== "4.0" || resultJson.environment !== config.worldEnvironment) {
    throw new WorldVerifyError("World protocol or environment mismatch", "world_context_mismatch");
  }
  if (!Array.isArray(resultJson.responses) || resultJson.responses.length !== 1) {
    throw new WorldVerifyError("Expected one Proof of Human response", "world_response_count");
  }
  const proof = resultJson.responses[0];
  if (!proof || typeof proof !== "object" || Array.isArray(proof)) {
    throw new WorldVerifyError("Invalid World proof response", "invalid_proof_shape");
  }
  const item = proof as Record<string, unknown>;
  if (item.identifier !== "proof_of_human" || Number(item.issuer_schema_id) !== 1) {
    throw new WorldVerifyError("World credential is not Proof of Human", "wrong_credential");
  }
  return item;
}

function decimalNullifier(value: unknown): string {
  if (typeof value !== "string" || !/^(?:0x[0-9a-fA-F]+|[0-9]+)$/.test(value)) {
    throw new WorldVerifyError("World nullifier is malformed", "invalid_nullifier");
  }
  return BigInt(value).toString(10);
}

/** Real client: verify the complete v4 IDKit result with World. */
export class HttpWorldVerifyClient implements WorldVerifyClient {
  async verify(rpId: string, resultJson: Record<string, unknown>, expectedSignal: string): Promise<WorldVerifyResult> {
    const proof = proofResponse(resultJson);
    if (typeof proof.signal_hash !== "string") {
      throw new WorldVerifyError("World signal hash missing", "signal_hash_mismatch");
    }
    assertSignalHashMatches({ signal_hash: proof.signal_hash }, expectedSignal);
    if (config.worldEnvironment === "staging" && !config.worldStagingVerificationToken) {
      throw new WorldVerifyError("World staging token missing", "staging_token_missing");
    }
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (config.worldEnvironment === "staging") {
      headers["x-staging-verification-token"] = config.worldStagingVerificationToken;
    }
    const response = await fetch(`${config.worldApiBase}/api/v4/verify/${rpId}`, {
      method: "POST",
      headers,
      body: JSON.stringify(resultJson),
    });
    const result = (await response.json()) as Record<string, unknown>;
    if (!response.ok || result.success !== true) {
      const code = typeof result.code === "string" ? result.code : "verify_failed";
      throw new WorldVerifyError(`World verify API returned ${response.status}: ${code}`, code);
    }
    if (result.environment !== config.worldEnvironment || result.action !== resultJson.action) {
      throw new WorldVerifyError("World verified a different environment or action", "world_context_mismatch");
    }
    if (!Array.isArray(result.results) || !result.results.some((item) => {
      if (!item || typeof item !== "object") return false;
      const verified = item as Record<string, unknown>;
      return verified.identifier === "proof_of_human" && verified.success === true;
    })) {
      throw new WorldVerifyError("World did not verify Proof of Human", "wrong_credential");
    }
    const nullifier = proof.nullifier === undefined ? undefined : decimalNullifier(proof.nullifier);
    if (result.nullifier !== undefined && nullifier !== undefined && decimalNullifier(result.nullifier) !== nullifier) {
      throw new WorldVerifyError("World verified a different nullifier", "nullifier_mismatch");
    }
    const sessionNullifier = Array.isArray(proof.session_nullifier)
      ? proof.session_nullifier[0]
      : proof.session_nullifier;
    return {
      success: true,
      signal_hash: proof.signal_hash,
      nullifier,
      session_id: typeof result.session_id === "string" ? result.session_id : undefined,
      session_nullifier: sessionNullifier === undefined ? undefined : decimalNullifier(sessionNullifier),
      identifier: "proof_of_human",
      issuer_schema_id: 1,
    };
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
