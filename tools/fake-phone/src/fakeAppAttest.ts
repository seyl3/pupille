import "reflect-metadata";
import { webcrypto, createHash } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { X509CertificateGenerator, X509Certificate, cryptoProvider, Extension } from "@peculiar/x509";
import { encode as cborEncode } from "cbor-x";

cryptoProvider.set(webcrypto as unknown as Crypto);

/**
 * Loads the persisted test root (written by generateTestRoot.ts) so the SAME root that was
 * exported to the backend via PUPILLE_APP_ATTEST_TEST_ROOT_PEM is used to sign this run's leaf
 * certificate — a fresh random root each call would never match what the backend process pinned
 * at boot.
 */
async function loadPersistedTestRoot(dir: string) {
  const certPath = `${dir}/test-root-cert.pem`;
  const keyPath = `${dir}/test-root-key.jwk.json`;
  if (!existsSync(certPath) || !existsSync(keyPath)) {
    throw new Error(
      `Test root not found at ${certPath} / ${keyPath}. Run: npx tsx src/generateTestRoot.ts ${dir}`
    );
  }
  const certPem = readFileSync(certPath, "utf8");
  const jwk = JSON.parse(readFileSync(keyPath, "utf8"));
  const alg = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" } as EcdsaParams & EcKeyGenParams;
  const privateKey = await webcrypto.subtle.importKey("jwk", jwk, alg, true, ["sign"]);
  const cert = new X509Certificate(certPem);
  return { cert, privateKey };
}

/**
 * STAND-IN FOR APPLE APP ATTEST — NOT A REAL ATTESTATION.
 *
 * Real App Attest (`DCAppAttestService`) proves a genuine, unmodified app instance running on
 * genuine Apple hardware, attested by Apple's servers. There is no way to produce a real one
 * without a physical iPhone. This builds a CBOR/COSE structure SHAPED like a real
 * `attestationObject` (per https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
 * but signed by a throwaway key generated in this process, so the backend's real CBOR/COSE
 * PARSING code path is exercised end-to-end. It proves the wiring, not device genuineness —
 * exactly mirroring backend/test/fixtures/buildAppAttestFixture.ts, which this is a copy of
 * for use outside the backend's own test tree (see docs/WORKLOG.md).
 */
export async function buildFakeAttestation(opts: { appId: string; clientDataHash: Buffer; testRootDir: string }) {
  const alg = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" } as EcdsaParams & EcKeyGenParams;

  const { cert: rootCert, privateKey: rootPrivateKey } = await loadPersistedTestRoot(opts.testRootDir);

  const credentialKeys = await webcrypto.subtle.generateKey(alg, true, ["sign", "verify"]);

  const rpIdHash = createHash("sha256").update(opts.appId, "utf8").digest();
  const flags = Buffer.from([0x40]);
  const counter = Buffer.alloc(4);
  const aaguid = Buffer.alloc(16); // zeroed; real value is "appattestdevelopment"/"appattest" per environment
  const credId = Buffer.from("fake-phone-key-id-000000001", "utf8").subarray(0, 20);
  const credIdLen = Buffer.alloc(2);
  credIdLen.writeUInt16BE(credId.length);

  const pubKeyJwk = await webcrypto.subtle.exportKey("jwk", credentialKeys.publicKey);
  const x = Buffer.from(pubKeyJwk.x!, "base64url");
  const y = Buffer.from(pubKeyJwk.y!, "base64url");
  const coseKey = new Map<number, unknown>([
    [1, 2],
    [3, -7],
    [-1, 1],
    [-2, x],
    [-3, y],
  ]);
  const credPubKeyCbor = Buffer.from(cborEncode(coseKey));
  const authData = Buffer.concat([rpIdHash, flags, counter, aaguid, credIdLen, credId, credPubKeyCbor]);

  const nonce = createHash("sha256").update(Buffer.concat([authData, opts.clientDataHash])).digest();
  const octetString = Buffer.concat([Buffer.from([0x04, nonce.length]), nonce]);
  const explicitTag1 = Buffer.concat([Buffer.from([0xa1, octetString.length]), octetString]);
  const sequence = Buffer.concat([Buffer.from([0x30, explicitTag1.length]), explicitTag1]);
  const nonceExtension = new Extension("1.2.840.113635.100.8.2", false, sequence);

  const leafCert = await X509CertificateGenerator.create({
    serialNumber: "02",
    subject: "CN=Fake-Phone Test Leaf (NOT Apple), O=PupilleFakePhone",
    issuer: rootCert.subject,
    notBefore: new Date(Date.now() - 86400_000),
    notAfter: new Date(Date.now() + 86400_000 * 30),
    signingAlgorithm: alg,
    publicKey: credentialKeys.publicKey,
    signingKey: rootPrivateKey,
    extensions: [nonceExtension],
  });

  const attestationObject = {
    fmt: "apple-appattest",
    attStmt: { x5c: [Buffer.from(leafCert.rawData)], receipt: Buffer.from("fake-phone-receipt", "utf8") },
    authData,
  };

  return {
    attestationObjectCbor: Buffer.from(cborEncode(attestationObject)),
    rootCertDer: Buffer.from(rootCert.rawData),
  };
}

export function derToPem(der: Buffer): string {
  const b64 = der.toString("base64");
  const lines = b64.match(/.{1,64}/g) ?? [];
  return `-----BEGIN CERTIFICATE-----\n${lines.join("\n")}\n-----END CERTIFICATE-----`;
}
