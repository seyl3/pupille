import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { before, describe, it } from "node:test";
import { embedProof, extractProof, verifyFile, verifyProof, type PupilleProof } from "../src/index.ts";
import { issueProof, makeIssuer, type TestIssuer } from "./issue.ts";

const fixture = async (name: string) => new Uint8Array(await readFile(new URL(`fixtures/${name}`, import.meta.url)));
const failed = (result: { checks: { id: string; passed: boolean }[] }) =>
  result.checks.filter((c) => !c.passed).map((c) => c.id);

let issuer: TestIssuer;
let photo: Uint8Array;
let otherPhoto: Uint8Array;
let proof: PupilleProof;

before(async () => {
  issuer = await makeIssuer();
  photo = await fixture("photo.jpg");
  otherPhoto = await fixture("other-photo.jpg");
  proof = await issueProof(issuer, photo);
});

describe("verifyProof", () => {
  it("accepts an untouched capture", async () => {
    const result = await verifyProof(proof, photo, { issuerPublicKey: issuer.publicKeyHex });
    assert.equal(result.verified, true);
    assert.equal(result.checks.length, 7);
    assert.equal(result.handle, "xyz");
    assert.equal(result.environment, "staging");
  });

  it("rejects one edited pixel byte", async () => {
    const edited = photo.slice();
    edited[edited.length - 100] ^= 0x01;
    const result = await verifyProof(proof, edited, { issuerPublicKey: issuer.publicKeyHex });
    assert.equal(result.verified, false);
    assert.deepEqual(failed(result), ["bytes", "commitment", "signature"]);
  });

  it("rejects a proof copied onto another photo", async () => {
    const result = await verifyProof(proof, otherPhoto, { issuerPublicKey: issuer.publicKeyHex });
    assert.deepEqual(failed(result), ["bytes", "commitment", "signature"]);
  });

  it("rejects certificates from a different issuer", async () => {
    const stranger = await makeIssuer();
    const result = await verifyProof(proof, photo, { issuerPublicKey: stranger.publicKeyHex });
    assert.deepEqual(failed(result), ["human", "capture"]);
  });

  it("rejects a post relabelled as another author", async () => {
    const relabelled = { ...proof, author: { ...proof.author, handle: "someone_else" } };
    const result = await verifyProof(relabelled, photo, { issuerPublicKey: issuer.publicKeyHex });
    assert.deepEqual(failed(result), ["author"]);
  });

  it("rejects an author signature from another key", async () => {
    const other = await issueProof(issuer, photo);
    const forged = { ...proof, postSignature: other.postSignature };
    const result = await verifyProof(forged, photo, { issuerPublicKey: issuer.publicKeyHex });
    assert.deepEqual(failed(result), ["signature"]);
  });

  it("rejects an edited caption and a removed caption", async () => {
    const edited = await verifyProof({ ...proof, caption: "hello osaka" }, photo, { issuerPublicKey: issuer.publicKeyHex });
    assert.deepEqual(failed(edited), ["caption"]);
    const removed = await verifyProof({ ...proof, caption: null }, photo, { issuerPublicKey: issuer.publicKeyHex });
    assert.deepEqual(failed(removed), ["caption"]);
  });

  it("accepts a post without a caption", async () => {
    const plain = await issueProof(issuer, photo, { caption: null });
    const result = await verifyProof({ ...plain, caption: "" }, photo, { issuerPublicKey: issuer.publicKeyHex });
    assert.equal(result.verified, true);
  });

  it("rejects a profile certified without Proof of Human", async () => {
    const weak = await issueProof(issuer, photo, { credential: "device" });
    const result = await verifyProof(weak, photo, { issuerPublicKey: issuer.publicKeyHex });
    assert.deepEqual(failed(result), ["human"]);
  });

  it("checks the capture app against a trusted list only when one is given", async () => {
    const sample = await issueProof(issuer, photo, { appId: "4397GAXGZ4.app.pupille.sample" });
    const open = await verifyProof(sample, photo, { issuerPublicKey: issuer.publicKeyHex });
    assert.equal(open.verified, true);
    assert.equal(open.appId, "4397GAXGZ4.app.pupille.sample");

    const trusted = await verifyProof(sample, photo, {
      issuerPublicKey: issuer.publicKeyHex, trustedAppIds: ["4397GAXGZ4.app.pupille.sample"],
    });
    assert.equal(trusted.verified, true);
    assert.equal(trusted.checks.length, 8);

    const untrusted = await verifyProof(sample, photo, {
      issuerPublicKey: issuer.publicKeyHex, trustedAppIds: ["4397GAXGZ4.app.pupille.dev"],
    });
    assert.deepEqual(failed(untrusted), ["app"]);
  });

  it("fails every check on garbage input instead of throwing", async () => {
    const garbage = { ...proof, profileCert: { certB64: "!!", sigB64: "??" }, postSignature: "nope" };
    const result = await verifyProof(garbage, photo, { issuerPublicKey: "not-hex" });
    assert.equal(result.verified, false);
  });
});

describe("proof embedded in a JPEG", () => {
  it("round-trips to the exact original bytes", async () => {
    const shared = embedProof(photo, proof);
    assert.ok(shared.length > photo.length);
    const { proof: extracted, imageBytes } = extractProof(shared);
    assert.deepEqual(imageBytes, photo);
    assert.deepEqual(extracted, proof);
  });

  it("keeps JFIF and EXIF segments first", async () => {
    const shared = embedProof(photo, proof);
    assert.deepEqual([...shared.subarray(0, 4)], [0xff, 0xd8, 0xff, 0xe0]); // SOI, APP0 (JFIF)
    const app0Length = (shared[4] << 8) | shared[5];
    const next = 4 + app0Length;
    assert.deepEqual([...shared.subarray(next, next + 2)], [0xff, 0xe1]); // APP1 (EXIF) still follows
  });

  it("replaces an earlier proof instead of stacking a second one", async () => {
    const other = await issueProof(issuer, photo, { handle: "abc" });
    const twice = embedProof(embedProof(photo, proof), other);
    const { proof: extracted, imageBytes } = extractProof(twice);
    assert.equal(extracted?.author.handle, "abc");
    assert.deepEqual(imageBytes, photo);
  });

  it("verifies a shared file end to end, and catches tampering inside it", async () => {
    const shared = embedProof(photo, proof);
    const good = await verifyFile(shared, { issuerPublicKey: issuer.publicKeyHex });
    assert.equal(good?.verified, true);

    const tampered = shared.slice();
    tampered[tampered.length - 100] ^= 0x01;
    const bad = await verifyFile(tampered, { issuerPublicKey: issuer.publicKeyHex });
    assert.equal(bad?.verified, false);
  });

  it("returns null for a JPEG without a proof, and rejects non-JPEG input", async () => {
    assert.equal(await verifyFile(photo, { issuerPublicKey: issuer.publicKeyHex }), null);
    assert.throws(() => extractProof(new TextEncoder().encode("not a jpeg")));
  });
});
