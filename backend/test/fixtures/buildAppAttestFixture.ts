import "reflect-metadata";
import { webcrypto } from "node:crypto";
import { createHash } from "node:crypto";
import {
  X509CertificateGenerator,
  X509Certificates,
  cryptoProvider,
  Extension,
} from "@peculiar/x509";
import { encode as cborEncode } from "cbor-x";

cryptoProvider.set(webcrypto as unknown as Crypto);

/**
 * Builds a HAND-BUILT, self-signed-chain App Attest fixture shaped exactly like the real
 * `attestationObject` CBOR structure documented at
 * https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server,
 * but signed by a throwaway test CA generated in-process — NOT a real Apple-issued certificate.
 * This proves backend/src/appattest/verify.ts's CBOR/COSE parsing and chain-verification wiring
 * is internally self-consistent. It does NOT prove compatibility with a real device's output —
 * see docs/WORKLOG.md "Untested".
 */
export async function buildAppAttestFixture(opts: { appId: string; clientDataHash: Buffer }) {
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

  // authData = rpIdHash(32) || flags(1) || counter(4) || aaguid(16) || credIdLen(2) || credId(N) || credPubKey(CBOR)
  const rpIdHash = createHash("sha256").update(opts.appId, "utf8").digest();
  const flags = Buffer.from([0x40]); // attested credential data present
  const counter = Buffer.alloc(4); // 0
  const aaguid = Buffer.from("appattestdevelopment", "ascii").subarray(0, 16).length === 16
    ? Buffer.concat([Buffer.from("appattestdevelopmen", "ascii")]).subarray(0, 16)
    : Buffer.alloc(16);
  const credId = Buffer.from("test-key-id-0123456789ab", "utf8").subarray(0, 20);
  const credIdLen = Buffer.alloc(2);
  credIdLen.writeUInt16BE(credId.length);

  const pubKeyJwk = await webcrypto.subtle.exportKey("jwk", credentialKeys.publicKey);
  const x = Buffer.from(pubKeyJwk.x!, "base64url");
  const y = Buffer.from(pubKeyJwk.y!, "base64url");
  const coseKey = new Map<number, unknown>([
    [1, 2], // kty: EC2
    [3, -7], // alg: ES256
    [-1, 1], // crv: P-256
    [-2, x],
    [-3, y],
  ]);
  const credPubKeyCbor = Buffer.from(cborEncode(coseKey));

  const authData = Buffer.concat([rpIdHash, flags, counter, aaguid, credIdLen, credId, credPubKeyCbor]);

  const nonce = createHash("sha256").update(Buffer.concat([authData, opts.clientDataHash])).digest();

  // Apple's nonce extension (1.2.840.113635.100.8.2): SEQUENCE { [1] EXPLICIT OCTET STRING }.
  // Hand-built as real DER (tags 0x30 SEQUENCE, 0xa1 context [1] constructed, 0x04 OCTET STRING)
  // so it round-trips through verify.ts's real asn1js structural parse, not just a byte match.
  const octetString = Buffer.concat([Buffer.from([0x04, nonce.length]), nonce]);
  const explicitTag1 = Buffer.concat([Buffer.from([0xa1, octetString.length]), octetString]);
  const sequence = Buffer.concat([Buffer.from([0x30, explicitTag1.length]), explicitTag1]);

  const nonceExtension = new Extension("1.2.840.113635.100.8.2", false, sequence);

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

  const attestationObject = {
    fmt: "apple-appattest",
    attStmt: {
      x5c: [Buffer.from(leafCert.rawData)],
      receipt: Buffer.from("fixture-receipt-bytes", "utf8"),
    },
    authData,
  };

  return {
    attestationObjectCbor: Buffer.from(cborEncode(attestationObject)),
    rootCertDer: Buffer.from(rootCert.rawData),
    expectedKeyId: credId.toString("base64url"),
    expectedCounter: 0,
  };
}
