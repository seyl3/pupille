# Agent worklog

## 2026-09-27: first physical-iPhone build

`ios/Pupille/Pupille.xcodeproj` now contains an installable SwiftUI device-check app. It can capture a camera photo and hash the exact bytes, create a temporary Secure Enclave P-256 signing key and verify its signature, and request a genuine App Attest attestation from Apple. Its **Verify on Mac** flow sends a fresh attestation to the standalone `backend/src/attestProbe.ts` server, which verifies Apple's certificate and a one-time challenge without Postgres. It does not yet create a World ID profile or publish to the feed. The earlier Linux handoff below remains the history of the protocol/backend implementation; its statement that no iOS target exists was true at that time.

An unsigned `xcodebuild` for generic physical iOS completed successfully on Xcode 27. The user then signed and installed the app on the paired iPhone with their Apple Team. Follow [IPHONE_TESTING.md](IPHONE_TESTING.md).

Physical iPhone 14 Pro (iOS 26.5.2) result reported by the user: camera captured 559,302 bytes and hashed them; Secure Enclave key signed and verified with Face ID; Apple's App Attest service returned 5,818 attestation bytes. The independent Mac probe subsequently returned `PASS: Mac verified Apple’s certificate`. This validates the signed app's real App Attest chain and challenge, but not World ID or publishing. The screenshots also showed unreadable white button labels on white buttons; the device-check UI now uses explicit contrasting colors for those buttons. The user supplied `pupille-logo.png`, now configured as the Home Screen icon, and requested a walkthrough for display name, version, and launch screen; this is recorded in [IPHONE_TESTING.md](IPHONE_TESTING.md).

Follow-up device retry exposed a real CBOR compatibility issue: Apple's untagged COSE key decoded to a plain object in `cbor-x`, while the verifier assumed a `Map` (the fixture encoder had added a Map tag). The probe returned `probe_internal_error` with `TypeError: cose.get is not a function`. `coseKeyToX963` now accepts either representation and validates 32-byte coordinates. A regression fixture uses the untagged wire encoding. Backend build and all 14 App Attest tests pass; after restarting the probe, the same iPhone returned `PASS: Mac verified Apple’s certificate`. The earlier connection failure was because the probe process had been stopped; local Wi-Fi alone did not start it.

World ID policy, confirmed with the user: the production app requires **Orb-backed Proof of Human**, because Selfie Check is weaker than the one-profile-per-unique-human claim. The no-Orb demo will use an official **staging Human test identity** in [World's simulator](https://simulator.worldcoin.org/), preferably through the World ID 4.0 `proofOfHuman` preset. The simulator repository documents native 4.0 staging Proof of Human via its MCP, but the specific iPhone-to-browser flow still needs an end-to-end test. If that browser flow only completes legacy Orb requests, the staging fallback is `orbLegacy` at profile creation; no per-post World session proof may be claimed in that mode. The [architecture](ARCHITECTURE.md) and [iPhone guide](IPHONE_TESTING.md) now encode this policy.

Backend `@worldcoin/idkit-core` is 4.3.0, but the installable iOS target does not include IDKit Swift yet. There is no Developer Portal app/RP/action, no server-held RP signing key, and no local Postgres setup on the current Mac. The backend schema and World fixture still reflect the earlier session-only model; they have not yet been migrated to the Proof of Human staging flow. The live verifier has not been proven against World v4: `backend/src/world/verifyClient.ts` expects a top-level `signal_hash` in the verify response, while the [current v4 examples](https://docs.world.org/world-id/idkit/integrate) put it in IDKit `responses[]` and show a verify response with `results[]` but no top-level `signal_hash`. Reconcile and test that contract before enabling live verification. The configured verify base was updated to `https://developer.world.org` per the current [API reference](https://docs.world.org/api-reference/developer-portal/verify).

## Status (2026-09-26, agent/linux-build)

All of 5A, 5B, 5D, and 5E are implemented with real, passing tests against real
infrastructure (no mocked database, no faked crypto checks). 5C (the actual iOS
app) is not implemented — it needs Xcode/the iOS SDK, which this Linux machine
cannot provide, and is listed under HANDOFF below rather than attempted.

**Proof commands, all exit 0 on this machine:**

```
cd backend && npm test                      # 32/32 tests, real Postgres
cd ios/PupilleCore && swift test             # 9/9 tests
cd tools/fake-phone && DATABASE_URL=... ./run.sh   # full E2E chain over real HTTP
```

Swift toolchain is NOT installed system-wide (no sudo available on this
machine — `yay -S swift-bin` failed on a `sudo` prompt for `patchelf`/
`libxml2-legacy`). Instead, Swift 6.1.2 is installed user-locally:

```
~/opt/swift-6.1.2-RELEASE-ubuntu22.04/   # extracted from the official
                                          # swift.org Ubuntu 22.04 tarball
~/opt/compat-libs/libncurses.so.6        # symlink -> /usr/lib/libncursesw.so.6
                                          # (Arch merged the ncurses soname;
                                          # the Ubuntu-built swift binaries
                                          # expect the old name)
```

`~/.bashrc` has `PATH`/`LD_LIBRARY_PATH` lines for this appended already. A
non-interactive shell (like this agent's Bash tool) needs:

```
export PATH="$HOME/opt/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/opt/compat-libs:$LD_LIBRARY_PATH"
```

Postgres is NOT running as a system service (starting it needs sudo/systemd
and `/var/lib/postgres` permissions this user doesn't have). Instead, a
user-owned data directory was initialized and is started manually:

```
~/pgdata/                                  # initdb -D ~/pgdata --encoding=UTF8 --locale=C.utf8
pg_ctl -D ~/pgdata -o "-p 5433 -k /tmp" -l ~/pgdata/logfile start
psql -p 5433 -h /tmp -U postgres -c "CREATE DATABASE pupille_test;"
export DATABASE_URL="postgresql://postgres@/pupille_test?host=/tmp&port=5433"
```

If this Postgres instance isn't running when tests are next attempted, start
it with the `pg_ctl` line above (data survives in `~/pgdata`) or run any other
real Postgres and point `DATABASE_URL` at it — `backend/src/db/schema.sql` is
plain, portable SQL.

## What's real vs. what's a stand-in

Everything the backend actually checks over the wire is real: signal_hash
recomputation via the genuine `@worldcoin/idkit-core/hashing` package,
CBOR/COSE parsing of App Attest attestation objects, X.509 chain building
against Apple's real pinned root CA (fetched from apple.com and byte-verified,
not hand-typed — see commit 7896b04 for why that distinction mattered), P-256
ECDSA verification with `ieee-p1363` encoding, and atomic nullifier/session-
nullifier replay protection via Postgres unique constraints.

What's a stand-in, always clearly labeled in the source as such:

- **Profile key**: `SoftwareProfileKey` (Swift, `ios/PupilleCore/Sources/PupilleCore/ProfileKey.swift`)
  and its Node/TS equivalents in `backend/test/fixtures/softwareKey.ts` and
  `tools/fake-phone/src/softwareProfileKey.ts` are plain software P-256 keys
  (via swift-crypto / Node's `crypto` module), standing in for
  `SecureEnclave.P256.Signing.PrivateKey`. They are API-compatible (raw r‖s
  signatures, 65-byte X9.63 public keys) so the protocol logic around them is
  fully real, but they are not hardware-backed and have no Face ID gate.
- **App Attest**: `tools/fake-phone/src/fakeAppAttest.ts` and
  `backend/test/fixtures/buildAppAttestFixture.ts` build a CBOR/COSE structure
  shaped exactly like Apple's documented `attestationObject`, signed by a
  throwaway test CA generated at runtime (`generateTestRoot.ts`) — never
  Apple's real root's private key, which nobody outside Apple has. The
  backend's `verifyAttestation` accepts a root-CA override
  (`PUPILLE_APP_ATTEST_TEST_ROOT_PEM`) ONLY for this purpose; it defaults to
  Apple's real pinned root and that override must never be set in production.
- **World ID proofs**: `FixtureWorldVerifyClient` (`backend/src/world/verifyClient.ts`)
  takes a hand-built response shaped per ARCHITECTURE.md §03/§12, but still
  runs the real `signal_hash` comparison — a fixture with a wrong signal fails
  exactly as it would against the real API. Enabled via
  `PUPILLE_WORLD_API_FIXTURE_MODE=1`. The real `HttpWorldVerifyClient` is
  implemented but has never been exercised against World's live API (no
  sandbox credentials available in this environment).

## HANDOFF (needs real hardware / access this machine cannot provide)

- **The entire iOS app (5C UI/services layer)**: SwiftUI views (`FeedView`,
  `CameraView`, `CreateProfileView`, `VerificationSheet`, etc.),
  `AVCaptureSession`-based `CameraService`, `DCAppAttestService`-based
  `AppAttestService`, `SecureEnclave.P256`-based `ProfileKeyService`, and the
  real `WorldIDService` using idkit-swift's generated bindings. None of these
  APIs exist on Linux — this is an Apple-framework restriction, not a
  toolchain gap. Needs Xcode + a physical iPhone running iOS 26 (per
  ARCHITECTURE.md §11: Secure Enclave and App Attest don't run in the
  Simulator either).
- **idkit-swift on Linux**: confirmed unusable here — `idkit-swift` ships a
  precompiled XCFramework (Rust core via UniFFI) that only links on Apple
  platforms (verified by attempting `swift build` against it: link errors for
  `uniffi_idkit_fn_func_*` symbols and `RustBuffer`, since the binary artifact
  isn't fetched/isn't compatible on `x86_64-unknown-linux-gnu`). PupilleCore's
  `hashSignal` therefore vendors its own Keccak-256
  (`ios/PupilleCore/Sources/PupilleCore/Keccak256.swift`), verified byte-exact
  against the real `@worldcoin/idkit-core/hashing` npm package's output for
  every §06 test vector plus an additional non-hex-signal case. This is a
  legitimate reimplementation of a fully-documented, standard algorithm
  (Keccak-256 + the documented `>> 8` truncation), not a guess.
- **Real Apple App Attest attestation objects and assertions**: never
  obtainable without a physical iPhone. `verifyAttestation` and
  `verifyAssertion`'s CBOR/COSE parsing, X.509 chain logic, and DER-signature
  verification are real and tested against hand-built fixtures (proves
  internal correctness), but have never parsed genuine Apple-issued output.
  See "Resolved after initial handoff" below for what assertion verification
  now covers.
- **World's live verify API** (`/api/v4/verify/{rp_id}`): no sandbox/staging
  credentials available in this environment. `HttpWorldVerifyClient` is
  implemented per ARCHITECTURE.md §03/§12's documented shape but has never
  made a real request. Exact response field names beyond what ARCHITECTURE.md
  directly quotes (`signal_hash`, `sybil_score`, `integrity_bundle`,
  `identifier`, `issuer_schema_id`, and presumably `nullifier`/`session_id`/
  `session_nullifier`) are this agent's best-documented understanding, not
  independently confirmed against a live response. See
  `backend/src/world/verifyClient.ts`'s `WorldVerifyResult` doc comment.
- **World App / IDKit interactive flow**: `returnTo` deep-linking and the
  production World App approval UI were not tested during this Linux build.
  The later iPhone test plan uses World's staging simulator and a Human test
  identity for Proof of Human integration, without treating it as a real Orb scan.
- **LiDAR flatness** (§06 `depthHash`, §12 `flatness` field): the byte-spec
  derivation handles depth bytes correctly (including the no-depth zero-hash
  case), but there is no LiDAR sensor to capture real depth data with, and the
  "recompute flatness on the backend" logic (§18 M6, `should`-tier) was not
  implemented — `flatness` is stored as `null` in every capture certificate
  this build produces.

## Untested (implemented, but not exercised against real external state)

- **`HttpWorldVerifyClient`** (the real, non-fixture World API client) — see
  HANDOFF above.
- **`npm audit`** reports 5 vulnerabilities (3 moderate, 1 high, 1 critical),
  all inside vitest's dev-only dependency chain (esbuild/vite's dev-server
  CORS advisory) — not reachable from production code or from how tests are
  actually run here. Not fixed this session; flagged rather than silently
  ignored.

## Resolved after initial handoff

- **`/v1/profiles/complete` never checked the App Attest assertion §07
  requires.** §07's own "Backend checks, in order" line ends with "App Attest
  assertion over `H('pupille:profile-assert:v1' || profileCommitment)`" —
  distinct from the per-capture assertion (`"pupille:assert:v1"`, checked on
  `/captures/:id/device`). The route accepted `profilePoP` (the profile key's
  own signature) and the World session proof, but never verified this
  assertion at all — a real, previously-undetected gap against the
  architecture doc's own spec, found by re-reading §07 line by line after
  finishing the capture-side assertion work, not by a test failing. Fixed:
  added `profileAssertClientDataHash` (`backend/src/proto/captureHasher.ts`)
  and wired `verifyAssertion` into `/profiles/complete`, using the App Attest
  key stored under the reservation's `app_attest_key_id`, in the order §07
  specifies (after `profilePoP`, before storing `session_id`/`sybil_score`).
  `tools/fake-phone` and the backend's `createProfile` test helper now build
  and submit a real profile-completion assertion (counter 1, before the
  capture-flow assertion's counter 2, since both draw from the same attested
  key's strictly-increasing counter). A new test proves a wrong-key
  assertion is rejected with `assertion_signature_invalid` AND that no
  profile row is created despite the World proof and `profilePoP` both being
  otherwise valid — the assertion check is not decorative. `npm test`: 32/32;
  `tools/fake-phone/run.sh`: still exit 0.
- **`HttpWorldVerifyClient` silently accepted an HTTP 200 response body with
  `success: false`.** It checked `signal_hash` but never checked `success`
  before returning the result as if verification had passed — unlike
  `FixtureWorldVerifyClient`, which already did. A real, reachable bug (World
  can return HTTP 200 with a logically-failed body), found by comparing the
  two client implementations rather than by live testing, since neither has
  been exercised against a real network call — see HANDOFF above. Fixed, and
  covered by a new `backend/test/worldVerifyClient.test.ts` (4 tests, via a
  mocked `fetch`, not a live call) that proves: a well-formed success is
  accepted, `success: false` is rejected, a `signal_hash` mismatch is
  rejected, and a non-2xx HTTP status is rejected. `npm test`: 31/31.
- **App Attest assertion verification is now wired into
  `/v1/captures/:id/device`.** Previously this endpoint verified
  `postSignature` and the commitment chain (the check that actually binds
  authorship) but stored the assertion bytes without independently verifying
  them. Now `verifyAssertion` (`backend/src/appattest/verify.ts`) parses the
  real assertion CBOR shape (`{signature: <DER ECDSA sig>, authenticatorData}`
  per Apple's documented format), checks `rpIdHash == SHA256(appId)`, verifies
  the DER signature over `SHA256(authenticatorData || clientDataHash)` under
  the App Attest public key stored at `/attest/register` (not a
  client-supplied key), and requires the counter to be strictly greater than
  the stored one (rejecting replay/clone) — exactly docs/ARCHITECTURE.md §08's
  "Assertion check" line. The stored counter is advanced after a successful
  check. `tools/fake-phone` and the backend's integration/fixture tests were
  updated to build and sign real assertions (via the same credential key each
  fixture's attestation used) instead of arbitrary placeholder bytes, so the
  full path — attest once, then verify a per-capture assertion signed by that
  same attested key — is now exercised, not just internally self-consistent
  pieces. Four new unit tests in `backend/test/appAttest.test.ts` prove
  `verifyAssertion` accepts a valid assertion and rejects: a non-advancing
  counter, a signature from the wrong key, and a mismatched clientDataHash.
  Still never exercised against a genuine Apple-issued assertion (no physical
  iPhone) — that residual gap is listed under HANDOFF above. `npm test`:
  27/27; `tools/fake-phone/run.sh`: still exit 0 end to end with the real
  assertion path now in the loop.
- **`tools/fake-phone/run.sh` leaked its backend process on every run.** The
  `trap 'kill $BACKEND_PID' EXIT` only killed `npm exec`'s own PID, not the
  `tsx`/`node` subprocesses `npm exec` spawns underneath it, so every
  invocation left a real backend process listening on :8787 after the script
  exited. Symptom actually hit in this session: a second run failed with
  `chain_invalid` because it silently talked to the *previous* run's stale
  backend process (pinned to that run's now-deleted test root) instead of the
  freshly started one — a confusing, non-deterministic failure that looked
  like a real regression but was purely a process-leak artifact. Fixed by
  starting the backend with `setsid` (its own process group) and killing the
  whole group (`kill -TERM -$BACKEND_PID`) on exit; verified clean with
  `pgrep` after a piped invocation (`./run.sh 2>&1 | tail`), which is exactly
  the shape that leaked before.

- **Apple nonce extension parsing** was upgraded from a raw-bytes substring
  containment check to a real DER structural parse (via `asn1js`, already a
  transitive dependency of `@peculiar/x509`) of the documented
  `SEQUENCE { [1] EXPLICIT OCTET STRING }` shape
  (`backend/src/appattest/verify.ts`'s `parseAppleNonceExtension`). Proven by
  a new test (`backend/test/appAttest.test.ts`, "rejects a nonce extension
  whose bytes contain the right nonce but are not real DER
  SEQUENCE{[1] OCTET STRING} structure") that constructs exactly the case a
  substring check could not catch — the correct nonce bytes present, but not
  wrapped in Apple's real ASN.1 shape — and confirms the new parser rejects
  it. Still not verified against a genuine Apple-issued certificate's actual
  DER encoding (no physical iPhone), but the parser now enforces real
  structure rather than a heuristic. `npm test`: 23/23.

## Design decisions worth flagging for review

- **`docs/AGENT_TASK.md` didn't exist at session start.** The user's
  `/goal` referenced `docs/AGENT_TASK.md` sections "5A–5E" and a
  `agent/linux-build` branch, none of which existed — only
  `docs/ARCHITECTURE.md` (build plan in §18, organized as milestones M0–M6,
  not sections 5A–5E) and a clean `main` branch existed. Per explicit user
  confirmation (AskUserQuestion, this session), `docs/AGENT_TASK.md` was
  authored from `ARCHITECTURE.md`'s content and the `agent/linux-build`
  branch created from scratch. If a differently-scoped task file was expected
  to already exist (e.g. authored in a separate session/device), reconcile
  against that rather than assuming this session's derived breakdown is
  authoritative.
- **`capture_challenges.pending_image`/`pending_depth` columns are NOT in
  ARCHITECTURE.md §12's schema table verbatim.** They were added because
  `/v1/captures/:id/device` receives the image bytes and `/v1/captures/:id/human`
  is the endpoint that actually persists `posts.image`, and the architecture
  doc doesn't specify how bytes move between those two calls without asking
  the client to re-upload. This was a real gap in the spec as written, filled
  with the simplest schema-consistent fix rather than silently deviating from
  the endpoint contract (e.g. by inventing an extra request body field on
  `/human`). Flagged here in case the intended design was different (e.g.
  storing directly against `postId` some other way).
- **Nullifier replay is claimed atomically at `/profiles/unique`**, via an
  insert into `world_session_nullifiers` keyed on `(nullifier, action)` —
  this is a deliberate strengthening beyond a literal reading of §12's
  endpoint table (which describes the duplicate check as happening against
  `profiles.nullifier`). A check-then-insert-at-`/complete` design has a
  TOCTOU race: two `/unique` calls for the same World ID could both pass the
  duplicate check before either has a row in `profiles`. This was caught by
  an integration test failing unexpectedly (see `a3ca075`'s commit message)
  and fixed rather than worked around.
- The Apple App Attest root CA was initially hand-typed from memory into the
  source and was WRONG in three base64 characters (confirmed by diffing
  against a real `curl` fetch of `apple.com`'s published PEM). Fixed by
  embedding the actually-fetched bytes and verifying the diff was clean before
  committing. Flagging this because it's exactly the kind of silent,
  plausible-looking error this worklog exists to catch — any other
  cryptographic material added later should be fetched or generated, never
  hand-typed.
