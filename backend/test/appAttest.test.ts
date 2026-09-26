import { describe, it, expect } from "vitest";
import { verifyAttestation, AppAttestVerificationError } from "../src/appattest/verify.js";
import { buildAppAttestFixture } from "./fixtures/buildAppAttestFixture.js";

const APP_ID = "test.pupille";

function toPem(der: Buffer): string {
  const b64 = der.toString("base64");
  const lines = b64.match(/.{1,64}/g) ?? [];
  return `-----BEGIN CERTIFICATE-----\n${lines.join("\n")}\n-----END CERTIFICATE-----`;
}

describe("App Attest verification (against a hand-built fixture, NOT a real Apple attestation — see docs/WORKLOG.md)", () => {
  it("parses a well-formed attestation object and extracts key/counter/aaguid", async () => {
    const clientDataHash = Buffer.alloc(32, 0x42);
    const fixture = await buildAppAttestFixture({ appId: APP_ID, clientDataHash });
    const rootPem = toPem(fixture.rootCertDer);

    const result = await verifyAttestation(fixture.attestationObjectCbor, clientDataHash, APP_ID, rootPem);

    expect(result.keyId).toBe(fixture.expectedKeyId);
    expect(result.counter).toBe(fixture.expectedCounter);
    expect(result.publicKeyX963.length).toBe(65);
    expect(result.publicKeyX963[0]).toBe(0x04);
  });

  it("rejects when the chain does not reach the pinned root", async () => {
    const clientDataHash = Buffer.alloc(32, 0x42);
    const fixture = await buildAppAttestFixture({ appId: APP_ID, clientDataHash });
    // Deliberately pass Apple's real root instead of the fixture's test root — the fixture's
    // leaf was signed by an unrelated throwaway CA, so the chain must not validate against it.
    await expect(verifyAttestation(fixture.attestationObjectCbor, clientDataHash, APP_ID)).rejects.toThrow(
      AppAttestVerificationError
    );
  });

  it("rejects when rpIdHash does not match the expected appId", async () => {
    const clientDataHash = Buffer.alloc(32, 0x42);
    const fixture = await buildAppAttestFixture({ appId: APP_ID, clientDataHash });
    const rootPem = toPem(fixture.rootCertDer);
    await expect(
      verifyAttestation(fixture.attestationObjectCbor, clientDataHash, "wrong.app.id", rootPem)
    ).rejects.toThrow(/rpIdHash/);
  });

  it("rejects when clientDataHash does not match the nonce baked into the certificate", async () => {
    const clientDataHash = Buffer.alloc(32, 0x42);
    const fixture = await buildAppAttestFixture({ appId: APP_ID, clientDataHash });
    const rootPem = toPem(fixture.rootCertDer);
    const wrongClientDataHash = Buffer.alloc(32, 0x99);
    await expect(
      verifyAttestation(fixture.attestationObjectCbor, wrongClientDataHash, APP_ID, rootPem)
    ).rejects.toThrow(/nonce/);
  });
});
