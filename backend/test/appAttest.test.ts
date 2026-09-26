import "reflect-metadata";
import { describe, it, expect } from "vitest";
import { webcrypto, createHash } from "node:crypto";
import { encode as cborEncode } from "cbor-x";
import { X509CertificateGenerator, Extension } from "@peculiar/x509";
import { verifyAttestation, verifyAssertion, AppAttestVerificationError } from "../src/appattest/verify.js";
import { buildAppAttestFixture, buildAssertionFixture } from "./fixtures/buildAppAttestFixture.js";

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

  it("accepts an untagged COSE map like the real iPhone sends", async () => {
    const clientDataHash = Buffer.alloc(32, 0x42);
    const fixture = await buildAppAttestFixture({ appId: APP_ID, clientDataHash, untaggedCoseKey: true });
    const result = await verifyAttestation(
      fixture.attestationObjectCbor, clientDataHash, APP_ID, toPem(fixture.rootCertDer)
    );
    expect(result.keyId).toBe(fixture.expectedKeyId);
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

  it("rejects a key ID different from the one the iPhone submitted", async () => {
    const hash = Buffer.alloc(32, 0x42);
    const fixture = await buildAppAttestFixture({ appId: APP_ID, clientDataHash: hash });
    await expect(
      verifyAttestation(fixture.attestationObjectCbor, hash, APP_ID, toPem(fixture.rootCertDer), "wrong-key-id")
    ).rejects.toMatchObject({ code: "key_id_mismatch" });
  });

  it("rejects a nonzero initial counter", async () => {
    const hash = Buffer.alloc(32, 0x42);
    const fixture = await buildAppAttestFixture({ appId: APP_ID, clientDataHash: hash, counter: 1 });
    await expect(
      verifyAttestation(fixture.attestationObjectCbor, hash, APP_ID, toPem(fixture.rootCertDer))
    ).rejects.toMatchObject({ code: "counter_invalid" });
  });

  it("rejects an App Attest key from the wrong environment", async () => {
    const hash = Buffer.alloc(32, 0x42);
    const fixture = await buildAppAttestFixture({ appId: APP_ID, clientDataHash: hash, aaguid: Buffer.alloc(16) });
    await expect(
      verifyAttestation(fixture.attestationObjectCbor, hash, APP_ID, toPem(fixture.rootCertDer))
    ).rejects.toMatchObject({ code: "aaguid_mismatch" });
  });

  it("rejects a credential ID not derived from the certificate public key", async () => {
    const hash = Buffer.alloc(32, 0x42);
    const fixture = await buildAppAttestFixture({
      appId: APP_ID, clientDataHash: hash, credentialId: Buffer.alloc(32, 0x99),
    });
    await expect(
      verifyAttestation(fixture.attestationObjectCbor, hash, APP_ID, toPem(fixture.rootCertDer))
    ).rejects.toMatchObject({ code: "credential_id_mismatch" });
  });

  it("rejects a nonce extension whose bytes contain the right nonce but are not real DER SEQUENCE{[1] OCTET STRING} structure", async () => {
    // This is exactly the case a substring-containment check (the pre-fix implementation) could
    // not distinguish from a genuine extension: the correct nonce bytes are present, but not
    // wrapped in Apple's documented ASN.1 shape. The real asn1js structural parse must still reject it.
    const clientDataHash = Buffer.alloc(32, 0x42);
    const alg = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" } as EcdsaParams & EcKeyGenParams;
    const rootKeys = await webcrypto.subtle.generateKey(alg, true, ["sign", "verify"]);
    const rootCert = await X509CertificateGenerator.createSelfSigned({
      serialNumber: "01",
      name: "CN=Test Root CA (NOT Apple), O=PupilleTest",
      notBefore: new Date(Date.now() - 86400_000),
      notAfter: new Date(Date.now() + 86400_000 * 3650),
      signingAlgorithm: alg,
      keys: rootKeys,
      extensions: [],
    });
    const credentialKeys = await webcrypto.subtle.generateKey(alg, true, ["sign", "verify"]);

    const rpIdHash = createHash("sha256").update(APP_ID, "utf8").digest();
    const flags = Buffer.from([0x40]);
    const counter = Buffer.alloc(4);
    const aaguid = Buffer.alloc(16);
    const credId = Buffer.from("test-key-id-0123456789ab", "utf8").subarray(0, 20);
    const credIdLen = Buffer.alloc(2);
    credIdLen.writeUInt16BE(credId.length);
    const pubKeyJwk = await webcrypto.subtle.exportKey("jwk", credentialKeys.publicKey);
    const coseKey = new Map<number, unknown>([
      [1, 2],
      [3, -7],
      [-1, 1],
      [-2, Buffer.from(pubKeyJwk.x!, "base64url")],
      [-3, Buffer.from(pubKeyJwk.y!, "base64url")],
    ]);
    const credPubKeyCbor = Buffer.from(cborEncode(coseKey));
    const authData = Buffer.concat([rpIdHash, flags, counter, aaguid, credIdLen, credId, credPubKeyCbor]);
    const nonce = createHash("sha256").update(Buffer.concat([authData, clientDataHash])).digest();

    // Malformed on purpose: the nonce bytes are simply concatenated with junk, not wrapped in
    // SEQUENCE { [1] EXPLICIT OCTET STRING }. A substring check would find `nonce` inside this
    // and incorrectly accept it.
    const malformedExtensionValue = Buffer.concat([Buffer.from([0xde, 0xad, 0xbe, 0xef]), nonce, Buffer.from([0x00])]);
    const nonceExtension = new Extension("1.2.840.113635.100.8.2", false, malformedExtensionValue);

    const leafCert = await X509CertificateGenerator.create({
      serialNumber: "02",
      subject: "CN=Test Leaf (NOT Apple), O=PupilleTest",
      issuer: rootCert.subject,
      notBefore: new Date(Date.now() - 86400_000),
      notAfter: new Date(Date.now() + 86400_000 * 30),
      signingAlgorithm: alg,
      publicKey: credentialKeys.publicKey,
      signingKey: rootKeys.privateKey,
      extensions: [nonceExtension],
    });

    const attestationObjectCbor = Buffer.from(
      cborEncode({
        fmt: "apple-appattest",
        attStmt: { x5c: [Buffer.from(leafCert.rawData)], receipt: Buffer.from("fixture-receipt-bytes", "utf8") },
        authData,
      })
    );
    const rootPem = toPem(Buffer.from(rootCert.rawData));

    await expect(verifyAttestation(attestationObjectCbor, clientDataHash, APP_ID, rootPem)).rejects.toThrow(
      AppAttestVerificationError
    );
  });
});

describe("App Attest assertion verification (against a hand-built fixture, per ARCHITECTURE.md §08)", () => {
  it("accepts a well-formed assertion signed by the attested credential key, with counter extraction", async () => {
    const clientDataHash = Buffer.alloc(32, 0x77);
    const attestation = await buildAppAttestFixture({ appId: APP_ID, clientDataHash: Buffer.alloc(32, 0x11) });
    const { assertionCbor } = await buildAssertionFixture({
      appId: APP_ID,
      clientDataHash,
      counter: 5,
      credentialPrivateKey: attestation.credentialPrivateKey,
    });

    const publicKeyResult = await verifyAttestation(
      attestation.attestationObjectCbor,
      Buffer.alloc(32, 0x11),
      APP_ID,
      toPem(attestation.rootCertDer)
    );

    const result = verifyAssertion(assertionCbor, clientDataHash, APP_ID, publicKeyResult.publicKeyX963, 0);
    expect(result.counter).toBe(5);
  });

  it("rejects an assertion whose counter does not advance past the stored counter (replay/clone)", async () => {
    const clientDataHash = Buffer.alloc(32, 0x77);
    const attestation = await buildAppAttestFixture({ appId: APP_ID, clientDataHash: Buffer.alloc(32, 0x11) });
    const { assertionCbor } = await buildAssertionFixture({
      appId: APP_ID,
      clientDataHash,
      counter: 3,
      credentialPrivateKey: attestation.credentialPrivateKey,
    });
    const publicKeyResult = await verifyAttestation(
      attestation.attestationObjectCbor,
      Buffer.alloc(32, 0x11),
      APP_ID,
      toPem(attestation.rootCertDer)
    );

    // storedCounter == 3, same as the assertion's counter — must be strictly greater, so this
    // must fail exactly as a replayed or cloned-key assertion would.
    expect(() => verifyAssertion(assertionCbor, clientDataHash, APP_ID, publicKeyResult.publicKeyX963, 3)).toThrow(
      /counter/
    );
  });

  it("rejects an assertion signed by the wrong key (not the one the caller claims attested it)", async () => {
    const clientDataHash = Buffer.alloc(32, 0x77);
    const attestation = await buildAppAttestFixture({ appId: APP_ID, clientDataHash: Buffer.alloc(32, 0x11) });
    const otherAttestation = await buildAppAttestFixture({ appId: APP_ID, clientDataHash: Buffer.alloc(32, 0x22) });
    const { assertionCbor } = await buildAssertionFixture({
      appId: APP_ID,
      clientDataHash,
      counter: 1,
      credentialPrivateKey: otherAttestation.credentialPrivateKey, // wrong key
    });
    const publicKeyResult = await verifyAttestation(
      attestation.attestationObjectCbor,
      Buffer.alloc(32, 0x11),
      APP_ID,
      toPem(attestation.rootCertDer)
    );

    expect(() => verifyAssertion(assertionCbor, clientDataHash, APP_ID, publicKeyResult.publicKeyX963, 0)).toThrow(
      /signature/
    );
  });

  it("rejects an assertion whose clientDataHash does not match what the server recomputed", async () => {
    const attestation = await buildAppAttestFixture({ appId: APP_ID, clientDataHash: Buffer.alloc(32, 0x11) });
    const { assertionCbor } = await buildAssertionFixture({
      appId: APP_ID,
      clientDataHash: Buffer.alloc(32, 0x77),
      counter: 1,
      credentialPrivateKey: attestation.credentialPrivateKey,
    });
    const publicKeyResult = await verifyAttestation(
      attestation.attestationObjectCbor,
      Buffer.alloc(32, 0x11),
      APP_ID,
      toPem(attestation.rootCertDer)
    );

    const wrongClientDataHash = Buffer.alloc(32, 0x99);
    expect(() => verifyAssertion(assertionCbor, wrongClientDataHash, APP_ID, publicKeyResult.publicKeyX963, 0)).toThrow(
      /signature/
    );
  });
});
