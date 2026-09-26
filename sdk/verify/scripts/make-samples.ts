/**
 * Writes demo files for the web verifier, signed by a throwaway demo issuer
 * (not Pupille's real key). Run: node verify/scripts/make-samples.ts
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { embedProof } from "../src/index.ts";
import { issueProof, makeIssuer } from "../test/issue.ts";

const out = new URL("../../web-verifier/samples/", import.meta.url);
const read = async (name: string) => new Uint8Array(await readFile(new URL(`../test/fixtures/${name}`, import.meta.url)));
const photo = await read("photo.jpg");
const otherPhoto = await read("other-photo.jpg");
const issuer = await makeIssuer();

const genuine = await issueProof(issuer, photo, { handle: "xyz", caption: "First light over Shibuya" });
const samplegram = await issueProof(issuer, photo, {
  handle: "sample_user", caption: "Shot in SampleGram", appId: "4397GAXGZ4.app.pupille.sample",
});
const unknownApp = await issueProof(issuer, photo, {
  handle: "xyz", caption: "Shot in an app you don't trust", appId: "ABCDE12345.com.example.unknown",
});

const edited = embedProof(photo, genuine);
edited[edited.length - 200] ^= 0x01;

await mkdir(out, { recursive: true });
await writeFile(new URL("genuine.jpg", out), embedProof(photo, genuine));
await writeFile(new URL("samplegram.jpg", out), embedProof(photo, samplegram));
await writeFile(new URL("edited.jpg", out), edited);
await writeFile(new URL("swapped.jpg", out), embedProof(otherPhoto, genuine));
await writeFile(new URL("unknown-app.jpg", out), embedProof(photo, unknownApp));
await writeFile(new URL("samples.json", out), JSON.stringify({
  issuerPublicKey: issuer.publicKeyHex,
  trustedAppIds: ["4397GAXGZ4.app.pupille.dev", "4397GAXGZ4.app.pupille.sample"],
}, null, 2) + "\n");
console.log("wrote samples to", out.pathname);
