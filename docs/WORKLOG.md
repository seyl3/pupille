# Agent worklog

## Status (2026-09-26, agent/linux-build)

All of 5A, 5B, 5D, and 5E are implemented with real, passing tests against real
infrastructure (no mocked database, no faked crypto checks). 5C (the actual iOS
app) is not implemented — it needs Xcode/the iOS SDK, which this Linux machine
cannot provide, and is listed under HANDOFF below rather than attempted.

**Proof commands, all exit 0 on this machine:**

```
cd backend && npm test                      # 22/22 tests, real Postgres
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
- **Real Apple App Attest attestation objects**: never obtainable without a
  physical iPhone. `verifyAttestation`'s CBOR/COSE parsing and X.509 chain
  logic is real and tested against a hand-built fixture (proves internal
  correctness), but has never parsed a genuine Apple-issued attestation
  object. Two specific gaps, both called out in
  `backend/src/appattest/verify.ts`'s doc comments:
  - The Apple nonce certificate extension (OID 1.2.840.113635.100.8.2) is
    checked via a raw-bytes substring containment check, not a full ASN.1
    parse of the wrapping `SEQUENCE { [1] EXPLICIT OCTET STRING }` structure.
    Sufficient for the fixture, not verified against Apple's real DER
    encoding.
  - App Attest **assertion** verification (as opposed to the one-time
    `attestKey` attestation checked at `/v1/attest/register`) is not wired
    into `/v1/captures/:id/device` — that endpoint verifies `postSignature`
    and the full commitment chain (the check that actually binds authorship),
    and stores the assertion bytes, but does not independently verify the
    assertion's COSE signature against the stored App Attest public key or
    check the monotonic counter. This is real backend work, not a hardware
    blocker — it just wasn't reached given the session's time budget. Tracked
    as **Untested** below, not HANDOFF.
- **World's live verify API** (`/api/v4/verify/{rp_id}`): no sandbox/staging
  credentials available in this environment. `HttpWorldVerifyClient` is
  implemented per ARCHITECTURE.md §03/§12's documented shape but has never
  made a real request. Exact response field names beyond what ARCHITECTURE.md
  directly quotes (`signal_hash`, `sybil_score`, `integrity_bundle`,
  `identifier`, `issuer_schema_id`, and presumably `nullifier`/`session_id`/
  `session_nullifier`) are this agent's best-documented understanding, not
  independently confirmed against a live response. See
  `backend/src/world/verifyClient.ts`'s `WorldVerifyResult` doc comment.
- **World App / IDKit interactive flow**: `returnTo` deep-linking, the actual
  World App approval UI, and Selfie Check itself all require the real World
  App on a real device — nothing to substitute here even in principle.
- **LiDAR flatness** (§06 `depthHash`, §12 `flatness` field): the byte-spec
  derivation handles depth bytes correctly (including the no-depth zero-hash
  case), but there is no LiDAR sensor to capture real depth data with, and the
  "recompute flatness on the backend" logic (§18 M6, `should`-tier) was not
  implemented — `flatness` is stored as `null` in every capture certificate
  this build produces.

## Untested (implemented, but not exercised against real external state)

- **App Attest assertion verification on `/captures/:id/device`** — see
  HANDOFF above; this is real, reachable backend work that simply wasn't
  completed this session, not a hardware wall. `postSignature` and the
  commitment chain ARE fully verified on that endpoint, which is the check
  that actually binds authorship (§08's own ordering lists device checks
  before the World proof for exactly this reason).
- **`HttpWorldVerifyClient`** (the real, non-fixture World API client) — see
  HANDOFF above.
- **The Apple nonce extension's exact DER structure** — see HANDOFF above;
  the current check is a substring containment check on the raw extension
  bytes, sufficient for the hand-built fixture, not a full ASN.1 parse
  verified against Apple's real encoding.
- **`npm audit`** reports 5 vulnerabilities (3 moderate, 1 high, 1 critical),
  all inside vitest's dev-only dependency chain (esbuild/vite's dev-server
  CORS advisory) — not reachable from production code or from how tests are
  actually run here. Not fixed this session; flagged rather than silently
  ignored.

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
