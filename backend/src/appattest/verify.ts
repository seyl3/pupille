import "reflect-metadata"; // required by @peculiar/x509's DI container
import { decode as cborDecode } from "cbor-x";
import { createHash, createPublicKey, verify as cryptoVerify, X509Certificate as NodeX509Certificate } from "node:crypto";
import { X509Certificate, X509ChainBuilder } from "@peculiar/x509";
import * as asn1js from "asn1js";

/**
 * Apple App Attest root CA. Fetched directly from
 * https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem on this
 * machine and verified (SHA-256 fingerprint 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:
 * 4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32, self-signed, CN=Apple App Attestation Root CA)
 * before being embedded here verbatim — never hand-typed, since a single wrong byte in a
 * pinned root cert silently breaks every chain verification. Pinned per
 * docs/ARCHITECTURE.md §12 ("Apple App Attest root CA (pinned on the backend)").
 */
export const APPLE_APP_ATTEST_ROOT_CA_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

export interface AttestationResult {
  keyId: string;
  publicKeyX963: Buffer;
  receiptCbor: Buffer;
  counter: number;
  aaguid: Buffer;
}

export class AppAttestVerificationError extends Error {
  constructor(message: string, public code: string) {
    super(message);
  }
}

interface AttestationObject {
  fmt: string;
  attStmt: { x5c: Buffer[]; receipt: Buffer };
  authData: Buffer;
}

function parseAuthData(authData: Buffer) {
  // https://www.w3.org/TR/webauthn-2/#sec-authenticator-data
  // rpIdHash(32) || flags(1) || counter(4) || aaguid(16) || credIdLen(2) || credId(N) || credPubKey(CBOR)
  if (authData.length < 55) {
    throw new AppAttestVerificationError("attestation authenticatorData too short", "auth_data_malformed");
  }
  const rpIdHash = authData.subarray(0, 32);
  const flags = authData[32];
  const counter = authData.readUInt32BE(33);
  const aaguid = authData.subarray(37, 53);
  const credIdLen = authData.readUInt16BE(53);
  if (credIdLen !== 32 || authData.length <= 55 + credIdLen) {
    throw new AppAttestVerificationError("attestation credential ID or public key malformed", "credential_malformed");
  }
  const credId = authData.subarray(55, 55 + credIdLen);
  const credPubKeyCbor = authData.subarray(55 + credIdLen);
  return { rpIdHash, flags, counter, aaguid, credId, credPubKeyCbor };
}

/** COSE_Key (EC2, P-256) -> 65-byte X9.63 uncompressed public key. */
function coseKeyToX963(coseKeyCbor: Buffer): Buffer {
  const cose: unknown = cborDecode(coseKeyCbor);
  // cbor-x can return either a Map or a plain object for CBOR maps. Apple's actual
  // COSE key takes the latter path; our hand-built fixture took the former.
  const field = (key: number): unknown => cose instanceof Map
    ? cose.get(key)
    : cose !== null && typeof cose === "object" && !Array.isArray(cose)
      ? (cose as Record<string, unknown>)[String(key)]
      : undefined;
  const kty = field(1);
  const crv = field(-1);
  const x = field(-2);
  const y = field(-3);
  if (kty !== 2 || crv !== 1) {
    throw new AppAttestVerificationError("expected COSE EC2 P-256 key", "unsupported_key_type");
  }
  if (!(x instanceof Uint8Array) || x.length !== 32 || !(y instanceof Uint8Array) || y.length !== 32) {
    throw new AppAttestVerificationError("COSE P-256 coordinates must be 32-byte byte strings", "bad_public_key");
  }
  return Buffer.concat([Buffer.from([0x04]), Buffer.from(x), Buffer.from(y)]);
}

/**
 * Verifies an App Attest `attestKey` attestation object against Apple's documented format
 * (https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server):
 * 1. CBOR-decode the attestation object, extract x5c certificate chain and authData.
 * 2. Verify the x5c chain up to the pinned Apple App Attest root CA.
 * 3. nonce = SHA256(authData || clientDataHash); verify it appears in the leaf cert's
 *    1.2.840.113635.100.8.2 extension.
 * 4. Verify RP ID, counter, AAGUID, certificate public key and credential ID.
 *
 * This parser is covered by hand-built fixtures and has also accepted a genuine Apple-issued
 * attestation from a physical iPhone 14 Pro through the Mac probe (2026-09-27). See
 * docs/WORKLOG.md for the scope of that device check.
 */
export async function verifyAttestation(
  attestationObjectCbor: Buffer,
  clientDataHash: Buffer,
  expectedAppId: string,
  /** Overridable only for tests, which sign fixtures with a throwaway test CA instead of Apple's real root. */
  rootCaPem: string = APPLE_APP_ATTEST_ROOT_CA_PEM,
  expectedKeyId?: string,
  environment: "development" | "production" = "development"
): Promise<AttestationResult> {
  const decoded = cborDecode(attestationObjectCbor) as AttestationObject;
  if (decoded.fmt !== "apple-appattest") {
    throw new AppAttestVerificationError(`unexpected fmt: ${decoded.fmt}`, "bad_format");
  }

  const toArrayBuffer = (buf: Buffer): ArrayBuffer => buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength) as ArrayBuffer;
  const leafCert = new X509Certificate(toArrayBuffer(decoded.attStmt.x5c[0]));
  const intermediates = decoded.attStmt.x5c.slice(1).map((der) => new X509Certificate(toArrayBuffer(der)));
  const root = new X509Certificate(toArrayBuffer(pemToDer(rootCaPem)));

  const chainBuilder = new X509ChainBuilder({ certificates: [...intermediates, root] });
  const chain = await chainBuilder.build(leafCert);
  const chainReachesRoot = chain.some((c) => c.equal(root));
  if (!chainReachesRoot) {
    throw new AppAttestVerificationError("certificate chain does not reach the pinned Apple root CA", "chain_invalid");
  }

  const { rpIdHash, counter, aaguid, credId, credPubKeyCbor } = parseAuthData(decoded.authData);

  if ((decoded.authData[32] & 0x40) === 0) {
    throw new AppAttestVerificationError("attested credential flag is missing", "auth_data_malformed");
  }
  if (counter !== 0) {
    throw new AppAttestVerificationError("initial App Attest counter must be zero", "counter_invalid");
  }
  const expectedAaguid = environment === "development"
    ? Buffer.from("appattestdevelop", "ascii")
    : Buffer.concat([Buffer.from("appattest", "ascii"), Buffer.alloc(7)]);
  if (!aaguid.equals(expectedAaguid)) {
    throw new AppAttestVerificationError("App Attest environment does not match", "aaguid_mismatch");
  }

  const expectedRpIdHash = createHash("sha256").update(expectedAppId, "utf8").digest();
  if (!rpIdHash.equals(expectedRpIdHash)) {
    throw new AppAttestVerificationError("rpIdHash does not match expected appId", "rp_id_mismatch");
  }

  const nonce = createHash("sha256").update(Buffer.concat([decoded.authData, clientDataHash])).digest();
  const nonceExtension = leafCert.extensions.find((e) => e.type === "1.2.840.113635.100.8.2");
  if (!nonceExtension) {
    throw new AppAttestVerificationError("leaf certificate missing Apple nonce extension", "nonce_extension_missing");
  }
  const extractedNonce = parseAppleNonceExtension(Buffer.from(nonceExtension.value));
  if (!extractedNonce.equals(nonce)) {
    throw new AppAttestVerificationError("nonce not found in certificate extension", "nonce_mismatch");
  }

  const certPublicKeyJwk = new NodeX509Certificate(decoded.attStmt.x5c[0]).publicKey.export({ format: "jwk" });
  if (certPublicKeyJwk.kty !== "EC" || certPublicKeyJwk.crv !== "P-256" || !certPublicKeyJwk.x || !certPublicKeyJwk.y) {
    throw new AppAttestVerificationError("credential certificate does not contain a P-256 key", "bad_public_key");
  }
  const certPublicKeyX963 = Buffer.concat([
    Buffer.from([0x04]),
    Buffer.from(certPublicKeyJwk.x, "base64url"),
    Buffer.from(certPublicKeyJwk.y, "base64url"),
  ]);
  const authDataPublicKeyX963 = coseKeyToX963(credPubKeyCbor);
  if (!authDataPublicKeyX963.equals(certPublicKeyX963)) {
    throw new AppAttestVerificationError("authenticator key differs from credential certificate", "bad_public_key");
  }
  const keyHash = createHash("sha256").update(certPublicKeyX963).digest();
  if (!credId.equals(keyHash)) {
    throw new AppAttestVerificationError("credential ID is not the certificate public-key hash", "credential_id_mismatch");
  }
  if (expectedKeyId && !Buffer.from(expectedKeyId, "base64url").equals(credId)) {
    throw new AppAttestVerificationError("iPhone key ID differs from attestation credential ID", "key_id_mismatch");
  }

  return {
    keyId: credId.toString("base64url"),
    publicKeyX963: certPublicKeyX963,
    receiptCbor: decoded.attStmt.receipt,
    counter,
    aaguid,
  };
}

/**
 * Parses Apple's App Attest nonce certificate extension (OID 1.2.840.113635.100.8.2), per
 * https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server:
 * "a single X.509 SEQUENCE containing a single element of type OCTET STRING, wrapped in an
 * explicit [1] context tag." Does a real DER structural parse (via asn1js, already a transitive
 * dependency of @peculiar/x509) rather than a substring containment check on the raw bytes.
 */
function parseAppleNonceExtension(extensionValue: Buffer): Buffer {
  const arrayBuffer = extensionValue.buffer.slice(
    extensionValue.byteOffset,
    extensionValue.byteOffset + extensionValue.byteLength
  ) as ArrayBuffer;
  const { result: sequence, offset } = asn1js.fromBER(arrayBuffer);
  if (offset === -1 || !(sequence instanceof asn1js.Sequence)) {
    throw new AppAttestVerificationError("nonce extension is not a DER SEQUENCE", "nonce_extension_malformed");
  }
  const [contextTagged] = sequence.valueBlock.value;
  if (
    !(contextTagged instanceof asn1js.Constructed) ||
    contextTagged.idBlock.tagClass !== 3 /* CONTEXT-SPECIFIC */ ||
    contextTagged.idBlock.tagNumber !== 1 /* [1] */
  ) {
    throw new AppAttestVerificationError("nonce extension missing explicit [1] context tag", "nonce_extension_malformed");
  }
  const [octetString] = contextTagged.valueBlock.value;
  if (!(octetString instanceof asn1js.OctetString)) {
    throw new AppAttestVerificationError("nonce extension [1] tag does not contain an OCTET STRING", "nonce_extension_malformed");
  }
  return Buffer.from(octetString.valueBlock.valueHexView);
}

export interface AssertionResult {
  authenticatorData: Buffer;
  counter: number;
}

interface AssertionObject {
  signature: Buffer;
  authenticatorData: Buffer;
}

/**
 * Verifies a per-capture App Attest assertion (`DCAppAttestService.generateAssertion`), per
 * docs/ARCHITECTURE.md §08's "Assertion check": signature over
 * `SHA256(authenticatorData || clientDataHash)` under the stored App Attest public key,
 * `rpIdHash == SHA256(appId)`, and counter strictly greater than the stored counter.
 *
 * Assertion format per https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
 * ("Verify the assertion"): CBOR map `{signature: <DER ECDSA sig>, authenticatorData: <bytes>}`.
 * Unlike the profile key's raw r‖s signatures, App Attest assertion signatures are standard DER
 * (Node's default `dsaEncoding`), which is what `DCAppAttestService` and CryptoKit's ASN.1
 * `derRepresentation` both produce for assertions.
 *
 * Apple signs the SHA-256 nonce of authenticatorData || clientDataHash. The
 * ECDSA verifier hashes its input once more, so pass the nonce, not the raw
 * concatenation. The original hand-built fixture signed the concatenation and
 * missed this difference on a physical iPhone.
 */
export function verifyAssertion(
  assertionCbor: Buffer,
  clientDataHash: Buffer,
  expectedAppId: string,
  storedPublicKeyX963: Buffer,
  storedCounter: number
): AssertionResult {
  const decoded = cborDecode(assertionCbor) as AssertionObject;
  if (!decoded.signature || !decoded.authenticatorData) {
    throw new AppAttestVerificationError("assertion missing signature or authenticatorData", "assertion_malformed");
  }

  const { rpIdHash, counter } = parseAssertionAuthData(decoded.authenticatorData);
  const expectedRpIdHash = createHash("sha256").update(expectedAppId, "utf8").digest();
  if (!rpIdHash.equals(expectedRpIdHash)) {
    throw new AppAttestVerificationError("assertion rpIdHash does not match expected appId", "rp_id_mismatch");
  }

  if (counter <= storedCounter) {
    throw new AppAttestVerificationError(
      `assertion counter ${counter} is not greater than stored counter ${storedCounter} (possible replay/clone)`,
      "counter_not_advancing"
    );
  }

  const nonce = createHash("sha256").update(Buffer.concat([decoded.authenticatorData, clientDataHash])).digest();
  const keyObject = x963ToNodePublicKey(storedPublicKeyX963);
  const valid = cryptoVerify("sha256", nonce, keyObject, decoded.signature);
  if (!valid) {
    throw new AppAttestVerificationError("assertion signature does not verify under the stored App Attest key", "assertion_signature_invalid");
  }

  return { authenticatorData: decoded.authenticatorData, counter };
}

/** authenticatorData for an assertion: rpIdHash(32) || flags(1) || counter(4). No attested credential data. */
function parseAssertionAuthData(authData: Buffer) {
  if (authData.length < 37) {
    throw new AppAttestVerificationError("assertion authenticatorData too short", "assertion_malformed");
  }
  const rpIdHash = authData.subarray(0, 32);
  const counter = authData.readUInt32BE(33);
  return { rpIdHash, counter };
}

function x963ToNodePublicKey(publicKeyX963: Buffer) {
  if (publicKeyX963.length !== 65 || publicKeyX963[0] !== 0x04) {
    throw new AppAttestVerificationError("expected 65-byte uncompressed X9.63 public key", "bad_public_key");
  }
  const x = publicKeyX963.subarray(1, 33);
  const y = publicKeyX963.subarray(33, 65);
  return createPublicKey({
    key: { kty: "EC", crv: "P-256", x: x.toString("base64url"), y: y.toString("base64url") },
    format: "jwk",
  });
}

function pemToDer(pem: string): Buffer {
  const b64 = pem.replace(/-----BEGIN CERTIFICATE-----/, "").replace(/-----END CERTIFICATE-----/, "").replace(/\s+/g, "");
  return Buffer.from(b64, "base64");
}
