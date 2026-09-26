import { describe, it, expect, vi, afterEach } from "vitest";
import { HttpWorldVerifyClient, WorldVerifyError } from "../src/world/verifyClient.js";
import { hashSignal } from "../src/proto/captureHasher.js";

/**
 * Unit tests for HttpWorldVerifyClient's response handling, via a mocked `fetch`. This does NOT
 * exercise a real network call to World's API (no sandbox credentials available — see
 * docs/WORKLOG.md HANDOFF), but it does prove the client's own logic around a response is correct:
 * exactly the kind of bug (accepting an HTTP 200 body with `success: false`) that would otherwise
 * only be caught by a real integration, which this session cannot run.
 */

const SIGNAL = "0x" + "ab".repeat(32);

function mockFetchOnce(status: number, body: unknown) {
  const fetchMock = vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("HttpWorldVerifyClient", () => {
  it("accepts a well-formed, successful response with a matching signal_hash", async () => {
    mockFetchOnce(200, { success: true, signal_hash: hashSignal(SIGNAL), session_id: "session_abc" });
    const client = new HttpWorldVerifyClient();
    const result = await client.verify("rp-id", {}, SIGNAL);
    expect(result.session_id).toBe("session_abc");
  });

  it("rejects an HTTP 200 response body with success: false, instead of silently accepting it", async () => {
    // This is exactly the gap this test was added to close: an HTTP-level 200 with a
    // logically-failed verification body must not be treated as a successful proof.
    mockFetchOnce(200, { success: false, signal_hash: hashSignal(SIGNAL) });
    const client = new HttpWorldVerifyClient();
    await expect(client.verify("rp-id", {}, SIGNAL)).rejects.toThrow(WorldVerifyError);
    await expect(client.verify("rp-id", {}, SIGNAL)).rejects.toThrow(/success: false/);
  });

  it("rejects a response whose signal_hash does not match what the server expected", async () => {
    mockFetchOnce(200, { success: true, signal_hash: "0x" + "00".repeat(32) });
    const client = new HttpWorldVerifyClient();
    await expect(client.verify("rp-id", {}, SIGNAL)).rejects.toThrow(/signal_hash mismatch/);
  });

  it("rejects a non-2xx HTTP response", async () => {
    mockFetchOnce(500, { error: "internal_error" });
    const client = new HttpWorldVerifyClient();
    await expect(client.verify("rp-id", {}, SIGNAL)).rejects.toThrow(/500/);
  });
});
