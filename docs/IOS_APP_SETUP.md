<!-- Original Linux-to-Mac implementation handoff. Current device results and World setup are in IPHONE_TESTING.md. -->

# Setting up `ios/Pupille` on a Mac

This was the original implementation handoff from Linux. The installable SwiftUI device-check app now exists and has passed camera, Secure Enclave, App Attest and Mac certificate checks on an iPhone 14 Pro. Use [IPHONE_TESTING.md](IPHONE_TESTING.md) for current setup. The remaining app work is the Proof of Human IDKit flow, durable profiles, publishing and feed UI.

Follow this in order — each step unblocks the next, and step 1 is the highest-risk item in
the whole project (see `docs/WORKLOG.md` HANDOFF), so don't leave it for last.

## 0. Prerequisites

- A Mac with Xcode 16+ (iOS 26 SDK) installed.
- A physical iPhone capable of iOS 26, registered in your Apple Developer account, with a
  provisioning profile that has the **App Attest** entitlement.
- A World Developer Portal staging app with `app_id`, `rp_id`, the `pupille-profile-v1`
  action and an RP signing key kept on the backend. The target credential is Orb-backed
  Proof of Human; the staging simulator provides a Human test identity without an Orb visit.
- `git clone` this repo (or `git fetch` + `git checkout agent/linux-build` if you already
  have it), and pull `ios/PupilleCore` in as-is — it's a normal SwiftPM package, no changes
  needed to use it from Xcode.

## 1. De-risk `WorldIDService` first (do this before anything else)

Per §11, start with the installed idkit-swift public `proofOfHuman` request API. Check
whether its current Swift wrapper exposes 4.0 `createSession`/`proveSession`; use the
public generated bindings if needed, and verify the exact initializer names from the
package you install. Do not substitute the weaker Selfie Check credential.

Steps:
1. Add `idkit-swift` as a Swift Package dependency in Xcode (`worldcoin/idkit-swift`,
   version 4.0.11 or later — check for a newer release that re-enables the public wrapper
   first, since that would remove this whole risk).
2. Add a small Proof of Human test flow to the existing iPhone target: build a uniqueness
   request (`action: "pupille-profile-v1"`, `environment: .staging`), display its connector
   URL, complete it with a Human identity in the World simulator on the Mac, and poll for
   a result. Confirm World verifies the returned proof before building the profile UI.
3. If it doesn't compile or the generated bindings don't behave as documented: fall back
   per §19 — the backend can drive IDKit itself via `@worldcoin/idkit-core` 4.3.0 (already a
   dependency in `backend/`) and hand the app a `connectorURI` to open, with the app just
   polling the backend instead of IDKit directly. This changes `WorldIDService` from an
   IDKit-Swift wrapper into a thin backend-polling client — more backend work, less iOS SDK
   risk. Decide this before building the rest of `ProofCoordinator` around one approach.

## 2. Extend the existing Xcode project

1. Open `ios/Pupille/Pupille.xcodeproj`. The bundle ID is `app.pupille.dev`, with camera and
   Face ID usage strings and an App Attest entitlement already configured. Keep Xcode signing
   and `PUPILLE_APP_ID` aligned as described in [IPHONE_TESTING.md](IPHONE_TESTING.md).
2. Add local package dependency `ios/PupilleCore` for `CaptureHasher` and `ProofVerifier`.
   The current device lab uses its own temporary key; the real profile flow needs a
   persistent Secure Enclave key.
3. Add `idkit-swift` only after step 1 identifies the correct Proof of Human request API.
4. Add the Keychain storage needed for the durable profile key and app session.

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
   - `PUPILLE_WORLD_API_BASE` — leave as `https://developer.world.org` unless World
     gives you a different sandbox host.
   - **Do not set** `PUPILLE_WORLD_API_FIXTURE_MODE` or `PUPILLE_APP_ATTEST_TEST_ROOT_PEM`
     — both are test-only escape hatches (`backend/src/config.ts`'s own comments say so);
     leaving either set in production defeats the pinning they're meant to bypass only for
     tests.
4. Point the app's `APIClient` base URL at the deployed backend instead of `localhost:8787`.

## 6. Run the real two-phone demo

Once the full app is installed and points at the backend:
1. Create `@handle` on phone A using a staging Human identity — uniqueness, then a 4.0
   Proof of Human session if the simulator flow supports it — and Face ID. Confirm the
   profile cert says `staging` and records the verified credential.
2. Take a photo, Post & Verify. With 4.0 sessions, cancel the simulator approval on the
   first attempt to prove the draft-on-cancel path, then retry and approve. On the legacy
   staging fallback, skip the per-post World approval and label that limit in the UI.
3. Confirm the post appears with the verified glyph.
4. Open the same feed on phone B, confirm it verifies independently.
5. Run the three tamper attacks from §18-M5 against a real published post (flip a byte in
   the stored image, relabel the author, copy a capture cert onto another image) and confirm
   `VerificationSheet` shows Unverified on both phones — the detection logic itself is
   already unit-tested in `ios/PupilleCore/Tests/PupilleCoreTests/ProofVerifierTests.swift`,
   this step is confirming the real UI reflects it correctly.
6. Try creating a second profile with the same simulator identity on either phone — confirm it's
   refused with `one_profile_per_human` and shows the existing handle.

## 7. Submission deliverables

- `FEEDBACK.md` per §17's template — start this the moment you begin step 1, with real
  timestamps, not backfilled afterward.
- 2–4 minute demo video (Mac screen capture with the iPhone mirrored) covering the steps in
  §18's demo script.
- README with an AI-usage disclosure and the feedback log.
- Submit with at least 1 hour to spare before the deadline (§18: Sunday 09:00 JST).
