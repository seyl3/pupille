import { createServer } from "node:http";
import { randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { IDKit, proofOfHuman } from "@worldcoin/idkit-core";
import { signRequest } from "@worldcoin/idkit-core/signing";
import { hashSignal } from "./proto/captureHasher.js";

// IDKit 4.3.0 loads its bundled WASM through fetch(file:). Node's fetch does not
// support file URLs, so serve only that local bundled file through a Response.
const networkFetch = globalThis.fetch;
globalThis.fetch = (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
  const url = input instanceof URL ? input : typeof input === "string" ? new URL(input) : input.url ? new URL(input.url) : null;
  if (url?.protocol === "file:" && url.pathname.endsWith("/idkit_wasm_bg.wasm")) {
    const bytes = await readFile(fileURLToPath(url));
    return new Response(bytes, { headers: { "content-type": "application/wasm" } });
  }
  return networkFetch(input, init);
}) as typeof fetch;

// A standalone staging check before the full Pupille profile flow exists. It never
// stores a profile or claims production Orb verification. The connector URL is
// shown only on a loopback web page because it contains an ephemeral encryption key.
const appId = process.env.PUPILLE_WORLD_APP_ID;
const rpId = process.env.PUPILLE_RP_ID;
const action = process.env.PUPILLE_WORLD_ACTION ?? "pupille-profile-v1";
const signingKey = process.env.PUPILLE_RP_SIGNING_KEY_HEX;

if (!appId?.startsWith("app_") || !rpId?.startsWith("rp_") || !signingKey) {
  throw new Error("Set PUPILLE_WORLD_APP_ID, PUPILLE_RP_ID, and PUPILLE_RP_SIGNING_KEY_HEX in .env.world.local");
}
if (!/^(0x)?[0-9a-fA-F]{64}$/.test(signingKey)) {
  throw new Error("PUPILLE_RP_SIGNING_KEY_HEX must be a 32-byte hex key");
}

type ProbeState = "waiting" | "verifying" | "passed" | "failed";
let state: ProbeState = "waiting";
let message = "Waiting for a Human test identity in World Simulator.";

function asRecord(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("World returned an invalid result object");
  }
  return value as Record<string, unknown>;
}

function checkIdkitResult(value: unknown, expectedNonce: string, signal: string): Record<string, unknown> {
  const result = asRecord(value);
  if (result.protocol_version !== "4.0" || result.environment !== "staging") {
    throw new Error("Expected a World ID 4.0 staging proof");
  }
  if (result.action !== action || result.nonce !== expectedNonce) {
    throw new Error("World proof action or nonce does not match the request");
  }
  if (!Array.isArray(result.responses) || result.responses.length !== 1) {
    throw new Error("Expected exactly one Proof of Human response");
  }
  const human = asRecord(result.responses[0]);
  if (human.identifier !== "proof_of_human" || human.issuer_schema_id !== 1) {
    throw new Error("World returned a credential other than Proof of Human");
  }
  if (typeof human.signal_hash !== "string" || human.signal_hash.toLowerCase() !== hashSignal(signal).toLowerCase()) {
    throw new Error("World proof signal does not match this test request");
  }
  if (typeof human.nullifier !== "string" || !/^0x[0-9a-fA-F]+$/.test(human.nullifier)) {
    throw new Error("World proof has no valid uniqueness nullifier");
  }
  return result;
}

async function verifyWithWorld(result: Record<string, unknown>): Promise<void> {
  const response = await fetch(`https://developer.world.org/api/v4/verify/${rpId}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(result),
  });
  const body = asRecord(await response.json());
  if (!response.ok || body.success !== true) {
    const code = typeof body.code === "string" ? body.code : `HTTP ${response.status}`;
    const detail = typeof body.detail === "string" ? `: ${body.detail}` : "";
    const failedResults = Array.isArray(body.results)
      ? body.results.flatMap((item) => {
          const result = asRecord(item);
          return typeof result.code === "string" ? [result.code] : [];
        })
      : [];
    const resultCodes = failedResults.length ? ` (proof results: ${failedResults.join(", ")})` : "";
    throw new Error(`World verification failed (HTTP ${response.status}): ${code}${detail}${resultCodes}`);
  }
  if (body.environment !== "staging" || body.action !== action) {
    throw new Error("World verified a different environment or action");
  }
  if (!Array.isArray(body.results) || !body.results.some((item) => {
    const verified = asRecord(item);
    return verified.identifier === "proof_of_human" && verified.success === true;
  })) {
    throw new Error("World did not verify the Proof of Human credential");
  }
  const localHuman = asRecord((result.responses as unknown[])[0]);
  if (typeof body.nullifier === "string" && body.nullifier.toLowerCase() !== String(localHuman.nullifier).toLowerCase()) {
    throw new Error("World verification nullifier differs from the proof");
  }
}

const rpSignature = signRequest({ signingKeyHex: signingKey, action });
const signal = `0x${randomBytes(32).toString("hex")}`;
const request = await IDKit.request({
  app_id: appId as `app_${string}`,
  action,
  rp_context: {
    rp_id: rpId,
    nonce: rpSignature.nonce,
    created_at: rpSignature.createdAt,
    expires_at: rpSignature.expiresAt,
    signature: rpSignature.sig,
  },
  allow_legacy_proofs: false,
  environment: "staging",
}).preset(proofOfHuman({ signal }));

const simulatorUrl = `https://simulator.worldcoin.org/?connect_url=${encodeURIComponent(request.connectorURI)}`;
const page = `<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pupille World ID staging probe</title>
<style>body{font:17px system-ui;max-width:640px;margin:8vh auto;padding:20px;line-height:1.5;background:#111;color:#fff}a{display:inline-block;padding:14px 20px;border-radius:12px;background:#fff;color:#111;text-decoration:none;font-weight:700}small{color:#aaa}</style>
<h1>World ID staging test</h1>
<p>Request a 4.0 Proof of Human from a simulator <strong>Human</strong> identity. This test does not create a Pupille profile.</p>
<p><a href="${simulatorUrl}" target="_blank" rel="noreferrer">Open World Simulator</a></p>
<p id="status">Waiting for a Human test identity in World Simulator.</p>
<small>Keep this page open. The Mac verifies the result with World and shows PASS or FAIL here.</small>
<script>setInterval(async()=>{try{const r=await fetch('/status',{cache:'no-store'});const s=await r.json();document.getElementById('status').textContent=s.state.toUpperCase()+': '+s.message}catch{}},1000)</script>
</html>`;

createServer((req, res) => {
  res.setHeader("cache-control", "no-store");
  if (req.url === "/status") {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ state, message }));
    return;
  }
  if (req.url !== "/") {
    res.writeHead(404).end();
    return;
  }
  res.setHeader("content-type", "text/html; charset=utf-8");
  res.end(page);
}).listen(8790, "127.0.0.1", () => {
  console.log("World ID staging probe ready: http://127.0.0.1:8790");
});

void request.pollUntilCompletion({ timeout: 10 * 60_000 }).then(async (completion) => {
  if (!completion.success) throw new Error(`IDKit request failed: ${completion.error}`);
  state = "verifying";
  message = "World proof received. Verifying with the Developer Portal.";
  const result = checkIdkitResult(completion.result, rpSignature.nonce, signal);
  await verifyWithWorld(result);
  state = "passed";
  message = "World verified a staging Proof of Human. No Orb scan or production identity was used.";
  console.log(message);
}).catch((error: unknown) => {
  state = "failed";
  message = error instanceof Error ? error.message : "Unknown World ID error";
  console.error(`World ID staging probe failed: ${message}`);
});
