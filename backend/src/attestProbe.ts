import { createHash, randomBytes } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { verifyAttestation, AppAttestVerificationError } from "./appattest/verify.js";

// A narrow device-to-server integration probe. It uses the production Apple root pin and the
// same verifier as /v1/attest/register, but has no database or World ID dependency. It stores
// only short-lived challenges in memory and does not log attestation bytes or key IDs.
const appId = process.env.PUPILLE_APP_ID;
if (!appId) throw new Error("PUPILLE_APP_ID must be set to TEAM_ID.bundle.identifier");
const environment = process.env.PUPILLE_APP_ATTEST_ENVIRONMENT ?? "development";
if (environment !== "development" && environment !== "production") {
  throw new Error("PUPILLE_APP_ATTEST_ENVIRONMENT must be development or production");
}
const port = Number(process.env.PORT ?? 8788);
const challenges = new Map<string, { bytes: Buffer; expiresAt: number }>();

function json(res: ServerResponse, status: number, body: object) {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(body));
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const parts: Buffer[] = [];
  let size = 0;
  for await (const part of req) {
    const chunk = Buffer.from(part);
    size += chunk.length;
    if (size > 100_000) throw new Error("request_too_large");
    parts.push(chunk);
  }
  return JSON.parse(Buffer.concat(parts).toString("utf8")) as Record<string, unknown>;
}

createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/healthz") {
    return json(res, 200, { ok: true, appId, environment });
  }
  if (req.method === "POST" && req.url === "/challenge") {
    const id = randomBytes(16).toString("hex");
    const bytes = randomBytes(32);
    challenges.set(id, { bytes, expiresAt: Date.now() + 5 * 60_000 });
    return json(res, 200, { challengeId: id, challenge: bytes.toString("hex") });
  }
  if (req.method === "POST" && req.url === "/verify") {
    try {
      const body = await readJson(req);
      const challengeId = body.challengeId;
      const keyId = body.keyId;
      const attestationObject = body.attestationObject;
      if (typeof challengeId !== "string" || typeof keyId !== "string" || typeof attestationObject !== "string") {
        return json(res, 400, { error: "missing_fields" });
      }
      const pending = challenges.get(challengeId);
      challenges.delete(challengeId);
      if (!pending || pending.expiresAt <= Date.now()) {
        return json(res, 400, { error: "challenge_expired" });
      }
      const clientDataHash = createHash("sha256").update(pending.bytes).digest();
      const result = await verifyAttestation(
        Buffer.from(attestationObject, "base64"),
        clientDataHash,
        appId,
        undefined, // use Apple's pinned App Attest root, never the fixture override
        keyId,
        environment
      );
      return json(res, 200, { verified: true, keyId: result.keyId, counter: result.counter, environment });
    } catch (error) {
      if (error instanceof AppAttestVerificationError) {
        console.warn(`App Attest rejected: ${error.code}`);
        return json(res, 400, { error: error.code });
      }
      console.error("App Attest probe error:", error);
      return json(res, 500, { error: "probe_internal_error" });
    }
  }
  return json(res, 404, { error: "not_found" });
}).listen(port, "0.0.0.0", () => {
  console.log(`App Attest probe listening on port ${port} for app ID ${appId} (${environment})`);
});
