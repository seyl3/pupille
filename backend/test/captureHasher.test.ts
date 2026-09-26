import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  profileCommitment,
  profileSignal,
  imageHash,
  depthHash,
  clientDataHash,
  assertionHash,
  captureCommitment,
  worldSignal,
  hashSignal,
  hex,
  hexDecode,
} from "../src/proto/captureHasher.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

interface Vectors {
  inputs: {
    imageBytesAscii: string;
    depthBytesAscii: string;
    challengeHex: string;
    assertionAscii: string;
    profileIdHex: string;
    profilePublicKeyHex: string;
    handle: string;
  };
  expected: {
    profileCommitment: string;
    imageHash: string;
    depthHash: string;
    clientDataHash: string;
    assertionHash: string;
    captureCommitment: string;
    clientDataHashNoDepth: string;
    captureCommitmentNoDepth: string;
    signalHashProfileSignal: string;
    signalHashWorldSignal: string;
    signalHashWorldSignalNoDepth: string;
  };
}

// Shared fixture — symlinked to ios/PupilleCore/Tests/PupilleCoreTests/Fixtures/section06-vectors.json.
// Both language suites read the SAME file so they cannot silently drift apart.
const vectors: Vectors = JSON.parse(readFileSync(path.join(__dirname, "fixtures/section06-vectors.json"), "utf8"));

describe("§06 byte spec — shared fixture", () => {
  const { inputs, expected } = vectors;
  const imgBytes = Buffer.from(inputs.imageBytesAscii, "ascii");
  const depthBytes = Buffer.from(inputs.depthBytesAscii, "ascii");
  const challenge = hexDecode(inputs.challengeHex);
  const profileId = hexDecode(inputs.profileIdHex);
  const profilePublicKey = hexDecode(inputs.profilePublicKeyHex);

  it("profilePublicKey is 65 bytes (X9.63 uncompressed)", () => {
    expect(profilePublicKey.length).toBe(65);
  });

  it("profileCommitment matches", () => {
    expect(hex(profileCommitment(profileId, profilePublicKey, inputs.handle))).toBe(expected.profileCommitment);
  });

  it("imageHash matches", () => {
    expect(hex(imageHash(imgBytes))).toBe(expected.imageHash);
  });

  it("depthHash matches", () => {
    expect(hex(depthHash(depthBytes))).toBe(expected.depthHash);
  });

  it("clientDataHash matches (with depth)", () => {
    const iHash = imageHash(imgBytes);
    const dHash = depthHash(depthBytes);
    expect(hex(clientDataHash(iHash, dHash, challenge))).toBe(expected.clientDataHash);
  });

  it("assertionHash matches", () => {
    expect(hex(assertionHash(Buffer.from(inputs.assertionAscii, "ascii")))).toBe(expected.assertionHash);
  });

  it("captureCommitment matches (with depth)", () => {
    const iHash = imageHash(imgBytes);
    const dHash = depthHash(depthBytes);
    const aHash = assertionHash(Buffer.from(inputs.assertionAscii, "ascii"));
    expect(hex(captureCommitment(iHash, dHash, challenge, aHash, profileId, profilePublicKey))).toBe(
      expected.captureCommitment
    );
  });

  it("clientDataHash and captureCommitment match with no depth (32 zero bytes)", () => {
    const iHash = imageHash(imgBytes);
    const noDepth = depthHash(null);
    expect(noDepth.equals(Buffer.alloc(32, 0))).toBe(true);
    expect(hex(clientDataHash(iHash, noDepth, challenge))).toBe(expected.clientDataHashNoDepth);
    const aHash = assertionHash(Buffer.from(inputs.assertionAscii, "ascii"));
    expect(hex(captureCommitment(iHash, noDepth, challenge, aHash, profileId, profilePublicKey))).toBe(
      expected.captureCommitmentNoDepth
    );
  });

  it("signal_hash matches for profileSignal and worldSignal, using the real IDKit hashSignal", () => {
    const pCommitment = profileCommitment(profileId, profilePublicKey, inputs.handle);
    expect(hashSignal(profileSignal(pCommitment))).toBe(expected.signalHashProfileSignal);

    const iHash = imageHash(imgBytes);
    const dHash = depthHash(depthBytes);
    const aHash = assertionHash(Buffer.from(inputs.assertionAscii, "ascii"));
    const cCommitment = captureCommitment(iHash, dHash, challenge, aHash, profileId, profilePublicKey);
    expect(hashSignal(worldSignal(cCommitment))).toBe(expected.signalHashWorldSignal);

    const cCommitmentNoDepth = captureCommitment(iHash, depthHash(null), challenge, aHash, profileId, profilePublicKey);
    expect(hashSignal(worldSignal(cCommitmentNoDepth))).toBe(expected.signalHashWorldSignalNoDepth);
  });
});
