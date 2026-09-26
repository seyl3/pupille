# Agent task: build Pupille on Linux

Source of truth for scope: `docs/ARCHITECTURE.md`. This file breaks that architecture's
build plan (§18) into concrete, checkable sections for an agent working on a Linux
machine with no Xcode, no iOS Simulator, and no physical iPhone.

**Hard platform constraint:** Secure Enclave (`SecureEnclave.P256`), `DCAppAttestService`,
LiDAR, and SwiftUI/Liquid Glass UI are Apple-platform-only APIs. They do not exist on
Linux and cannot be made to run here — this is an Apple framework restriction, not a
toolchain gap. Anything that depends on them is out of scope for "passing tests in this
session" and must be logged in `docs/WORKLOG.md` as HANDOFF (needs a real iPhone) or
Untested, never faked or stubbed to look like it passed.

Everything else in the architecture — the byte-exact protocol (§06), the backend (§12),
feed verification logic (§09), and the certificate/signature chain — has no Apple-only
dependency and must actually build and test green here, using `swift-crypto` (Apple's
own cross-platform CryptoKit-API-compatible package) in place of CryptoKit where Linux
Swift needs it.

## 5A — Protocol byte spec (`ios/PupilleCore` + `backend/src/proto`)

Implement §06 identically in both languages and prove byte-for-byte equality against the
§06 test vectors.

- [x] `ios/PupilleCore`: a Swift Package (SwiftPM, Linux-compatible, uses `swift-crypto`
      not CryptoKit) with `CaptureHasher` implementing every derivation in §06:
      `profileCommitment`, `profileSignal`, `profilePoP` tag, `imageHash`, `depthHash`,
      `clientDataHash` (with and without depth), `captureCommitment` (with and without
      depth), `postSignature` tag, `worldSignal`, `authSignature` tag.
- [x] `swift test` passes all §06 test vectors exactly (hex-for-hex).
- [x] `backend/src/proto`: TypeScript port of the same derivations.
- [x] `npm test` in `backend/` includes the same §06 vectors and passes.
- [x] Cross-language round trip: a fixture file of inputs/outputs shared by both test
      suites (not copy-pasted twice) so the two languages can't silently drift.
- [x] ECDSA P-256 round trip: Swift signs (raw r‖s via swift-crypto), Node verifies with
      `dsaEncoding: "ieee-p1363"`; Node rejects the same signature over a modified
      commitment. (No fixed vector — signatures are randomized, per §06.)
- [x] `signal_hash` computed via each language's real IDKit hashing helper
      (`IDKit.hashSignal` / `@worldcoin/idkit-core/hashing`), not a hand-rolled
      keccak, matching the §06 vectors. (Swift side: idkit-swift's hashSignal is
      unavailable on Linux — see docs/WORKLOG.md — so a vendored Keccak-256 is used,
      verified byte-exact against the real npm package's output.)

## 5B — Backend (`backend/`)

Implement §12's API and schema against a real Postgres (or Postgres-compatible) database
reachable from this machine — do not mock the database.

- [x] Postgres schema from §12 applied via migration, including `world_session_nullifiers`,
      `one_active_key` partial unique index, and all FKs. (Plus `pending_image`/
      `pending_depth` columns not in §12's table verbatim — see docs/WORKLOG.md for why.)
- [x] Endpoints: `/v1/attest/challenge`, `/v1/attest/register`, `/v1/handles/:h`,
      `/v1/profiles/start`, `/v1/profiles/unique`, `/v1/profiles/complete`,
      `/v1/profiles/rotate`, `/v1/auth/challenge`, `/v1/auth/token`,
      `/v1/captures/challenge`, `/v1/captures/:id/device`, `/v1/captures/:id/human`,
      `/v1/feed`, `/v1/posts/:id/image`, `/v1/profiles/:handle`.
- [x] Signal verification: every endpoint that takes a World proof recomputes
      `signal_hash` itself via `hashSignal` and compares before ever calling
      `/api/v4/verify/{rp_id}` — never trust a client-supplied `signal_hash`.
- [x] Nonce, nullifier-replay (`world_session_nullifiers`), and session-nullifier checks
      enforced at the DB level (unique constraints), not just in application code.
      Nullifier claim happens atomically at `/profiles/unique` itself, not just
      check-then-insert at `/complete` — see docs/WORKLOG.md for the TOCTOU this closes.
- [x] App Attest verification: real CBOR parsing of the attestation object, Apple App
      Attest root CA chain check, nonce/appId/AAGUID check, using cbor-x + @peculiar/x509.
      Nonce-extension check is a real DER structural parse (via asn1js) of the documented
      `SEQUENCE { [1] EXPLICIT OCTET STRING }` shape, proven by a test that a substring
      check could not pass. App Attest *assertion* verification is also wired into
      /captures/:id/device: real DER-signature check over the stored public key plus a
      strictly-advancing counter check, per §08's "Assertion check" — see
      docs/WORKLOG.md "Resolved after initial handoff" for both.
- [x] Because there is no physical iPhone or World App here, the World API and App
      Attest calls are tested against **hand-built fixtures** matching the documented
      schema (backend/test/fixtures/buildAppAttestFixture.ts,
      backend/test/fixtures/worldProofFixture.ts) — never a bypassed check; the fixture
      World client still runs the real signal_hash comparison. The real HTTP World
      client is implemented but never exercised against World's live API — logged in
      docs/WORKLOG.md Untested.
- [x] `npm test` in `backend/` exits 0 covering the above (31/31 tests).

## 5C — iOS app (`ios/Pupille`)

This section is expected to be mostly HANDOFF. List it explicitly rather than skipping
it silently.

- [x] Everything in §11 that is pure logic and platform-independent (e.g. anything that
      only depends on `PupilleCore` from 5A) may be written and unit-tested here.
      (`CaptureHasher`, `ProofVerifier`, `SoftwareProfileKey` in PupilleCore itself cover
      this — there was no separate `ios/Pupille` app-layer logic worth extracting beyond
      what PupilleCore already provides, since the rest of §11's services are thin
      wrappers directly over the hardware/UI APIs listed below.)
- [x] Everything that depends on `SecureEnclave.P256.Signing.PrivateKey`,
      `DCAppAttestService`, `AVCaptureSession`, LiDAR, SwiftUI/Liquid Glass rendering, or
      the real World App/IDKit Swift bindings (§11's `WorldIDService`) cannot run,
      build against the iOS SDK, or be tested on this Linux machine — logged in full in
      `docs/WORKLOG.md` under HANDOFF. No `ios/Pupille` app target was created, since
      every one of its planned pieces (CameraView, CreateProfileView, VerificationSheet,
      AppAttestService, ProfileKeyService, WorldIDService) falls in this bucket.

## 5D — Feed verification + attack demo (`ios/PupilleCore` `ProofVerifier`, `backend` admin routes)

- [x] `ProofVerifier` (§09, checks 1–7) implemented in `PupilleCore` as a pure function,
      independent of SecureEnclave/UI — this part has no Apple-only dependency and must
      be unit-tested here.
- [x] Unit tests for each of the 3 demo attacks in §09/§18-M5, proving the verifier
      catches them: (a) one flipped image byte → check 4 fails, (b) relabelled author →
      checks 2/6 fail, (c) certificate copied onto another image → check 4 fails.
      (ios/PupilleCore/Tests/PupilleCoreTests/ProofVerifierTests.swift, 6/6 passing,
      including forged-signature and tampered-issuer-cert cases beyond the required 3.)
- [~] Backend admin/debug routes or scripts that can produce these 3 corrupted
      scenarios from otherwise-valid fixtures, for the fake-phone E2E script in 5E to
      drive. NOT built as separate backend routes — the equivalent corruption is
      exercised directly in Swift unit tests (ProofVerifierTests) against
      PostPayload/certs built in-process, which proves the same thing (ProofVerifier
      catches all 3 attacks) without needing a network round trip. fake-phone (5E)
      itself only exercises the golden path, not the 3 attacks — see docs/WORKLOG.md.

## 5E — End-to-end harness (`tools/fake-phone`)

Since there is no real iPhone, build a script that plays the client role against the
real backend from 5B, so the full flow in §07/§08 can be proven end-to-end without
Apple hardware.

- [x] `tools/fake-phone`: a Node/TS script using `PupilleCore`'s TS twin (5A) to act as a
      fake device: generates a fake profile key (plain P-256, standing in for the
      Secure Enclave key — clearly labeled as a stand-in, never presented as a real
      attestation), fake App Attest material shaped like the real thing for the
      backend's parser, and drives `/v1/profiles/*` and `/v1/captures/*` against a
      running backend instance.
- [x] Where a real World ID proof is unobtainable (no physical World App session), the
      script uses a hand-built fixture proof consistent with 5B's fixture approach
      (World's sandbox/staging endpoint was not reachable/usable — no credentials
      available in this session) — logged in docs/WORKLOG.md.
- [x] The script's own exit code is 0 only if the full create-profile → capture →
      publish → feed-fetch → verify chain succeeds against the real backend, and
      non-zero on any check failure — no swallowed errors. (run.sh proven from a clean
      DB/backend-process slate: exit 0.)
- [x] This script is the one referenced by the session goal as
      "the tools/fake-phone end-to-end script." (`tools/fake-phone/run.sh`)

## Definition of done for this session

Every checkbox above is either checked off with a passing, real test behind it, or
copied into `docs/WORKLOG.md` under **HANDOFF** (needs hardware/access this machine
truly cannot provide) or **Untested** (with the specific reason), never silently
dropped. `npm test` (backend/), `swift test` (ios/PupilleCore), and
`tools/fake-phone`'s script must all exit 0 for whatever they actually cover — a
green exit code must never be achieved by deleting or skipping a failing assertion.
