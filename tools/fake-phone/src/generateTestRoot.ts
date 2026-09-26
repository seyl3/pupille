import "reflect-metadata";
import { webcrypto } from "node:crypto";
import { X509CertificateGenerator, cryptoProvider } from "@peculiar/x509";
import { writeFileSync } from "node:fs";

cryptoProvider.set(webcrypto as unknown as Crypto);

/**
 * One-shot helper: generates the fake-phone test root CA + key and writes them to disk, so the
 * SAME test root can be exported to the backend process (PUPILLE_APP_ATTEST_TEST_ROOT_PEM)
 * before it boots, and reused by fakeAppAttest.ts to sign the leaf certificate in this run.
 * Run via: npx tsx src/generateTestRoot.ts <output-dir>
 */
async function main() {
  const outDir = process.argv[2] ?? ".";
  const alg = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" } as EcdsaParams & EcKeyGenParams;
  const keys = await webcrypto.subtle.generateKey(alg, true, ["sign", "verify"]);
  const cert = await X509CertificateGenerator.createSelfSigned({
    serialNumber: "01",
    name: "CN=Fake-Phone Test Root (NOT Apple), O=PupilleFakePhone",
    notBefore: new Date(Date.now() - 86400_000),
    notAfter: new Date(Date.now() + 86400_000 * 3650),
    signingAlgorithm: alg,
    keys,
    extensions: [],
  });
  const jwkPrivate = await webcrypto.subtle.exportKey("jwk", keys.privateKey);

  const b64 = Buffer.from(cert.rawData).toString("base64");
  const pem = `-----BEGIN CERTIFICATE-----\n${(b64.match(/.{1,64}/g) ?? []).join("\n")}\n-----END CERTIFICATE-----\n`;

  writeFileSync(`${outDir}/test-root-cert.pem`, pem);
  writeFileSync(`${outDir}/test-root-key.jwk.json`, JSON.stringify(jwkPrivate));
  console.log(`Wrote ${outDir}/test-root-cert.pem and ${outDir}/test-root-key.jwk.json`);
}

main();
