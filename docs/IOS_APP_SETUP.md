<!-- Setup guide for building ios/Pupille on a Mac. Written from agent/linux-build once
     PupilleCore, the backend, and the fake-phone harness were done and tested (see
     docs/WORKLOG.md). Nothing in this file has been run — it's a precise plan derived from
     docs/ARCHITECTURE.md §11 and the already-built PupilleCore package, not a verified guide. -->

# Setting up `ios/Pupille` on a Mac

This picks up where `agent/linux-build` left off. `ios/PupilleCore` (the protocol spec,
`ProofVerifier`, and a software stand-in profile key) is done and tested — 9/9 `swift test`
passing, byte-exact against §06's vectors. What's missing is the actual SwiftUI app around
it, which needs Xcode and a physical iPhone (Secure Enclave and App Attest don't run in the
Simulator, per §11).

Follow this in order — each step unblocks the next, and step 1 is the highest-risk item in
the whole project (see `docs/WORKLOG.md` HANDOFF), so don't leave it for last.

## 0. Prerequisites

- A Mac with Xcode 16+ (iOS 26 SDK) installed.
- A physical iPhone capable of iOS 26, registered in your Apple Developer account, with a
  provisioning profile that has the **App Attest** entitlement.
- A World Developer Portal account with an app created, `app_id`/`rp_id` issued, and Selfie
  Check enabled for it (see §19's open questions — confirm 4.0 sessions are live where you
  test before building on the assumption that they are).
- `git clone` this repo (or `git fetch` + `git checkout agent/linux-build` if you already
  have it), and pull `ios/PupilleCore` in as-is — it's a normal SwiftPM package, no changes
  needed to use it from Xcode.

## 1. De-risk `WorldIDService` first (do this before anything else)

Per §11: idkit-swift 4.0.11's **public** wrapper doesn't expose `createSession`/
`proveSession` or the 4.0 Selfie preset yet. You have to call the **generated** (but public)
bindings directly — `IdKitBuilder.fromCreateSession`, `.fromProveSession`,
`.fromRequest(config: IdKitRequestConfig(action: ...))`, and `.constraints(...)` with
`CredentialType.selfie`. The exact initializer labels are generated code and may not match
§11's sketch exactly — **check them against the actual generated file in the package you
pull down**, don't assume the sketch compiles verbatim.

Steps:
1. Add `idkit-swift` as a Swift Package dependency in Xcode (`worldcoin/idkit-swift`,
   version 4.0.11 or later — check for a newer release that re-enables the public wrapper
   first, since that would remove this whole risk).
2. Write a throwaway single-view test target that does nothing but: build a uniqueness
   request (`action: "pupille-profile-v1"`), open the resulting `connectUrl()` in the World
   App, and poll for a result. Confirm you get a real proof back before writing any other
   app code.
3. If it doesn't compile or the generated bindings don't behave as documented: fall back
   per §19 — the backend can drive IDKit itself via `@worldcoin/idkit-core` 4.3.0 (already a
   dependency in `backend/`) and hand the app a `connectorURI` to open, with the app just
   polling the backend instead of IDKit directly. This changes `WorldIDService` from an
   IDKit-Swift wrapper into a thin backend-polling client — more backend work, less iOS SDK
   risk. Decide this before building the rest of `ProofCoordinator` around one approach.

## 2. Create the Xcode project

1. New Xcode project → iOS App → SwiftUI → name it `Pupille`, bundle ID matching what you
   registered for App Attest (e.g. `app.pupille` per §11's model, or your own reverse-DNS ID
   — just keep it consistent with what the backend's `PUPILLE_APP_ID` will be set to).
2. Add local package dependency: `ios/PupilleCore` (the path in this repo). This gives you
   `CaptureHasher`, `ProofVerifier`, and `SoftwareProfileKey` (a stand-in — do not use it for
   real signing, see step 4).
3. Add `idkit-swift` as a remote package dependency (confirmed working in step 1).
4. Info.plist keys (§11): `NSCameraUsageDescription`, `NSFaceIDUsageDescription`.
5. Signing & Capabilities: add the **App Attest** capability. Use the `development`
   environment for now — note this changes the expected AAGUID the backend checks against
   (`backend/src/appattest/verify.ts`'s `aaguid` field), so the backend needs to know which
   environment you're in.
6. Enable Keychain sharing (for `ProfileStore`, per §11).

## 3. Build the services, in dependency order

Build these bottom-up — each one is testable in isolation before the next depends on it.

1. **`ProfileKeyService`** — real Secure Enclave key, replacing `SoftwareProfileKey`.
   `PupilleCore`'s `ProfileKeyVerifier.verify` and `CaptureHasher`'s message-building
   functions (`profilePoPMessage`, `postSignatureMessage`, etc.) work identically whether
   the signature came from `SoftwareProfileKey` or a real
   `SecureEnclave.P256.Signing.PrivateKey` — same 64-byte raw r‖s output, same 65-byte X9.63
   public key. Use `SecAccessControl(.privateKeyUsage, .biometryCurrentSet)` per §11 so Face
   ID gates every signature.
2. **`AppAttestService`** — `DCAppAttestService.generateKey()` once on first launch, then
   `attestKey(_:clientDataHash:)` against a challenge from `POST /v1/attest/challenge`,
   submitted to `POST /v1/attest/register`. Per-capture: `generateAssertion(_:clientDataHash:)`.
   The backend's assertion verification (`backend/src/appattest/verify.ts`'s
   `verifyAssertion`) is already built and tested against a hand-built fixture — this is the
   first time it'll see a real assertion, so budget time for surprises in the real
   `authenticatorData` layout or DER signature encoding even though the fixture matches the
   documented format exactly.
3. **`CameraService`** — `AVCapturePhotoOutput`, full-screen, no photo-library import path
   (camera-only is part of the "Captured through Pupille" guarantee, §01).
4. **`WorldIDService`** — from step 1's de-risking work.
5. **`APIClient`** — typed wrapper over the endpoints already implemented and tested in
   `backend/src/routes/*.ts`. The request/response shapes match what `tools/fake-phone/src/main.ts`
   already sends — that script is a working reference client if anything is ambiguous.
6. **`ProofCoordinator`** — the state machine from §08's diagram, wiring 1–5 together.
7. **`FeedService`** — fetches posts, runs `PupilleCore.ProofVerifier.verify(...)` (already
   built, 6/6 tests passing including all 3 attack scenarios) on each one before display.
8. **`ProfileStore`** — SwiftData + Keychain, current profile/key version/drafts.

## 4. Build the views (§11's table)

`CreateProfileView` → `FeedView` → `CameraView` → `CapturePreviewView` → `PostView` →
`VerificationSheet` → `ProfileView`. These are straightforward SwiftUI once the services
above exist — the state machine in `ProofCoordinator` should drive nearly all of the
conditional UI (draft-on-cancel, failure screens per §07's IDKit-error-code mapping, etc.).

## 5. Deploy the backend somewhere the phone can reach

`backend/` currently only runs against `localhost:5433` Postgres for local testing. For the
phone to reach it:
1. Deploy to Railway or Fly (per §12) with a real Postgres addon.
2. Apply `backend/src/db/schema.sql` (or run `npx tsx src/db/migrate.ts` against the
   deployed DB — same script `tools/fake-phone/run.sh` uses locally).
3. Set real env vars — **do not** carry over the test-only ones:
   - `PUPILLE_RP_SIGNING_KEY_HEX` — generate a real 32-byte hex secret, not the dev default.
   - `PUPILLE_RP_ID` — your actual World `rp_id`.
   - `PUPILLE_APP_ID` — must match the bundle ID App Attest is registered under.
   - `PUPILLE_WORLD_API_BASE` — leave as `https://developer.worldcoin.org` unless World
     gives you a different sandbox host.
   - **Do not set** `PUPILLE_WORLD_API_FIXTURE_MODE` or `PUPILLE_APP_ATTEST_TEST_ROOT_PEM`
     — both are test-only escape hatches (`backend/src/config.ts`'s own comments say so);
     leaving either set in production defeats the pinning they're meant to bypass only for
     tests.
4. Point the app's `APIClient` base URL at the deployed backend instead of `localhost:8787`.

## 6. Run the real two-phone demo

Once both phones have the app installed and pointed at the real backend:
1. Create `@handle` on phone A — two World App approvals (uniqueness, then session), then
   Face ID. Confirm the profile cert comes back.
2. Take a photo, Post & Verify — cancel in the World App on the first attempt to prove the
   draft-on-cancel path (§08's alternative-scenario requirement), then retry and approve.
3. Confirm the post appears with the verified glyph.
4. Open the same feed on phone B, confirm it verifies independently.
5. Run the three tamper attacks from §18-M5 against a real published post (flip a byte in
   the stored image, relabel the author, copy a capture cert onto another image) and confirm
   `VerificationSheet` shows Unverified on both phones — the detection logic itself is
   already unit-tested in `ios/PupilleCore/Tests/PupilleCoreTests/ProofVerifierTests.swift`,
   this step is confirming the real UI reflects it correctly.
6. Try creating a second profile with the same World ID on either phone — confirm it's
   refused with `one_profile_per_human` and shows the existing handle.

## 7. Submission deliverables

- `FEEDBACK.md` per §17's template — start this the moment you begin step 1, with real
  timestamps, not backfilled afterward.
- 2–4 minute demo video (Mac screen capture with the iPhone mirrored) covering the steps in
  §18's demo script.
- README with an AI-usage disclosure and the feedback log.
- Submit with at least 1 hour to spare before the deadline (§18: Sunday 09:00 JST).
