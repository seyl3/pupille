import { afterEach, describe, expect, it, vi } from "vitest";
import { HttpWorldVerifyClient, WorldVerifyError } from "../src/world/verifyClient.js";
import { hashSignal } from "../src/proto/captureHasher.js";

const signal = `0x${"ab".repeat(32)}`;
const proof = {
  protocol_version: "4.0",
  environment: "production",
  action: "pupille-profile-v1",
  nonce: "test-nonce",
  responses: [{
    identifier: "proof_of_human",
    issuer_schema_id: 1,
    signal_hash: hashSignal(signal),
    nullifier: "0x1234",
    proof: ["0x1", "0x2", "0x3", "0x4", "0x5"],
  }],
};
const accepted = {
  success: true,
  environment: "production",
  action: "pupille-profile-v1",
  nullifier: "0x1234",
  results: [{ identifier: "proof_of_human", success: true, nullifier: "0x1234" }],
};

function mockWorld(status: number, body: unknown) {
  const fetchMock = vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

afterEach(() => vi.unstubAllGlobals());

describe("live World 4.0 verifier contract", () => {
  it("accepts a successful Human proof and converts its nullifier for Postgres", async () => {
    const fetchMock = mockWorld(200, accepted);
    const result = await new HttpWorldVerifyClient().verify("rp_test", proof, signal);
    expect(result.nullifier).toBe("4660");
    expect(result.identifier).toBe("proof_of_human");
    expect(fetchMock).toHaveBeenCalledWith(expect.stringContaining("/api/v4/verify/rp_test"),
      expect.objectContaining({ body: JSON.stringify(proof) }));
  });

  it("rejects a forged local signal before calling World", async () => {
    const fetchMock = mockWorld(200, accepted);
    await expect(new HttpWorldVerifyClient().verify("rp_test", proof, "0xdead"))
      .rejects.toMatchObject({ code: "signal_hash_mismatch" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("rejects Selfie Check even if the response says success", async () => {
    const fetchMock = mockWorld(200, accepted);
    const selfie = { ...proof, responses: [{ ...proof.responses[0], identifier: "selfie", issuer_schema_id: 11 }] };
    await expect(new HttpWorldVerifyClient().verify("rp_test", selfie, signal))
      .rejects.toMatchObject({ code: "wrong_credential" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("rejects an unsuccessful verifier result", async () => {
    mockWorld(200, { ...accepted, success: false });
    await expect(new HttpWorldVerifyClient().verify("rp_test", proof, signal))
      .rejects.toThrow(WorldVerifyError);
  });

  it("rejects a different verified nullifier", async () => {
    mockWorld(200, { ...accepted, nullifier: "0x5678" });
    await expect(new HttpWorldVerifyClient().verify("rp_test", proof, signal))
      .rejects.toMatchObject({ code: "nullifier_mismatch" });
  });

  it("rejects a non-2xx verifier response", async () => {
    mockWorld(403, { code: "environment_not_allowed" });
    await expect(new HttpWorldVerifyClient().verify("rp_test", proof, signal))
      .rejects.toMatchObject({ code: "environment_not_allowed" });
  });
});
