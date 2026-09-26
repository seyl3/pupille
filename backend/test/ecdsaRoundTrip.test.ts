import { describe, it, expect, beforeAll } from "vitest";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { verifyProfileSignature } from "../src/proto/profileKey.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Cross-language round trip per docs/AGENT_TASK.md 5A: Swift signs (software P-256 via
// swift-crypto, standing in for SecureEnclave.P256 — see PupilleCore/Sources/PupilleCore/ProfileKey.swift),
// Node verifies with dsaEncoding: "ieee-p1363". Signatures are randomized (no fixed vector, per §06),
// so this is a live round trip, not a stored expected value.
//
// Requires a Swift toolchain on PATH (see docs/WORKLOG.md for how it's installed on this machine)
// and the pupille-sign-cli executable built from ios/PupilleCore.

const repoRoot = path.resolve(__dirname, "../..");
const pupilleCoreDir = path.join(repoRoot, "ios", "PupilleCore");
const cliPath = path.join(pupilleCoreDir, ".build", "debug", "pupille-sign-cli");

function signWithSwift(message: string): { publicKeyX963: Buffer; signature: Buffer } {
  const output = execFileSync(cliPath, [message], { encoding: "utf8" });
  const [pubKeyHex, sigHex] = output.trim().split("\n");
  return { publicKeyX963: Buffer.from(pubKeyHex, "hex"), signature: Buffer.from(sigHex, "hex") };
}

describe("ECDSA P-256 cross-language round trip (Swift signs, Node verifies)", () => {
  beforeAll(() => {
    try {
      execFileSync(cliPath, ["--help"], { stdio: "ignore" });
    } catch (e: unknown) {
      // pupille-sign-cli has no --help; any execution (even an error exit) proves the binary runs.
      // A genuine "not found" throws ENOENT, which we surface clearly.
      if ((e as NodeJS.ErrnoException).code === "ENOENT") {
        throw new Error(
          `pupille-sign-cli not built at ${cliPath}. Run: swift build --product pupille-sign-cli in ${pupilleCoreDir}`
        );
      }
    }
  });

  it("verifies a signature Swift produced over a message", () => {
    const message = Buffer.from("pupille:post-sig:v1" + "test-commitment-bytes", "utf8");
    const { publicKeyX963, signature } = signWithSwift(message.toString("utf8"));
    expect(publicKeyX963.length).toBe(65);
    expect(publicKeyX963[0]).toBe(0x04);
    expect(signature.length).toBe(64);
    expect(verifyProfileSignature(signature, message, publicKeyX963)).toBe(true);
  });

  it("rejects the same signature over a modified commitment", () => {
    const original = "pupille:post-sig:v1original-commitment";
    const tampered = "pupille:post-sig:v1tampered-commitment!";
    const { publicKeyX963, signature } = signWithSwift(original);
    expect(verifyProfileSignature(signature, Buffer.from(tampered, "utf8"), publicKeyX963)).toBe(false);
  });

  it("rejects a signature under the wrong public key", () => {
    const message = "some message";
    const { signature } = signWithSwift(message);
    const { publicKeyX963: otherKey } = signWithSwift("a different message, different key");
    expect(verifyProfileSignature(signature, Buffer.from(message, "utf8"), otherKey)).toBe(false);
  });
});
