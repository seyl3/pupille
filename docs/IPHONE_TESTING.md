# Testing Pupille on an iPhone

## Where the repo stands

`ios/Pupille/Pupille.xcodeproj` is the first installable iPhone app. It checks camera capture, Secure Enclave signing, and App Attest on a real device. Its **Verify on Mac** check sends a genuine attestation to the local `attest:probe` server, which validates Apple's certificate and the one-time challenge without Postgres. It does not yet create a World ID profile or publish a post. `ios/PupilleCore` is a separate Swift package containing the protocol hashers and feed proof verifier. `backend` is a Hono/Postgres API. `tools/fake-phone` exercises that API with software keys and fixture World proofs; its World result is simulated. See [WORKLOG.md](WORKLOG.md) for implementation coverage.

The phone's three device checks and the Mac's certificate check passed on an iPhone 14 Pro. The next milestone is to connect a durable profile and publishing flow to the full backend and verify a World ID **staging Proof of Human** proof. Pupille's production credential policy targets Orb-backed Proof of Human; the tester does not need an Orb scan for this staging demo.

## Do now: pair the iPhone

1. Open **Xcode → Settings → Accounts** and sign in with your Apple Account. Xcode 27 and its iPhoneOS SDK are installed on this Mac; check that your iPhone's iOS version is supported by this Xcode installation.
2. Connect the unlocked iPhone to the Mac with a data-capable cable. Tap **Trust This Computer** on the phone if prompted. Keep it unlocked for the first pairing.
3. In **Xcode 27**, open **Xcode → Open Developer Tool → Device Hub**. The older **Window → Devices and Simulators** menu no longer appears. Check that the phone appears under **Physical Devices** and finishes preparing. Because this iPhone runs iOS 26, pair it with a cable; Xcode 27's wireless pairing requires iOS 27 or later. If Xcode asks for Developer Mode, on the phone open **Settings → Privacy & Security → Developer Mode**, enable it, restart, and confirm after restart.

Once the iPhone appears under **Physical Devices**, continue below. “Screen Sharing Unavailable” on iOS 26 only affects mirroring in Device Hub; you can still install and run an app from Xcode.

## Install the device-check app

1. In Finder, open `ios/Pupille/Pupille.xcodeproj` from this repository. In Xcode, select the blue **Pupille** project icon, then the **Pupille** app target and **Signing & Capabilities**.
2. Leave **Automatically manage signing** on and choose your Team. The working device build uses bundle identifier `app.pupille.dev` and Apple Team ID `4397GAXGZ4`. If either changes, update the probe's `PUPILLE_APP_ID` to match.
3. In Xcode's toolbar, choose the **Pupille** scheme and your physical iPhone (shown as “gateway” in Device Hub), then press **Run** (⌘R). Xcode will install and launch the app. If Developer Mode is requested, enable it on the phone and retry.
4. In Pupille on the phone, tap **Open camera**, take a photo, and return. The app should show `PASS` and a SHA-256 prefix. Tap **Test Face ID key** and complete the prompt; it should show `PASS`. Tap **Test App Attest** while the phone has internet access; it should show `PASS` plus an attestation byte count.
5. For the independent Mac check, on the same Wi-Fi run `cd backend && PUPILLE_APP_ID=4397GAXGZ4.app.pupille.dev npm run attest:probe`. In the app's **Verify on Mac** card, use `http://mac.local:8788` (or the Mac's current Wi-Fi IP address) and tap **Verify with backend**. Expect `PASS: Mac verified Apple’s certificate`. This probe does not need Postgres and stores no account. Stop it with Ctrl-C after testing.

If the app says **Could not connect to the server**, first make sure that terminal command is still running. Sharing Wi-Fi does not start the server by itself. On the Mac, open `http://mac.local:8788/healthz` in a browser; it should return JSON with `"ok":true`. If `mac.local` does not resolve on the phone, use the Mac's current Wi-Fi IP in the app URL instead. If the app says **probe_internal_error**, inspect the probe's terminal output. On 2026-09-27, an untagged COSE map from the real iPhone exposed a parser assumption; the verifier now handles it and the phone check passes.

If **Run** fails, send the first red Xcode error and a screenshot of **Signing & Capabilities**. If a check inside the app fails, send its exact `FAIL` text. The app targets iOS 26. On 2026-09-27, the paired iPhone 14 Pro passed all three device checks and the independent Mac certificate check.

## Before testing the real Pupille app: identity and artwork

The device-check app uses a temporary identity. Its current app information is:

1. **Name under the Home Screen icon:** `Pupille` is set in `Pupille/Info.plist` as `CFBundleDisplayName`. To rename it later, select the blue project icon → **Pupille** target → **General → Identity → Display Name** (or edit that plist entry).
2. **App icon:** the supplied 1024 × 1024 `pupille-logo.png` is already in `Pupille/Assets.xcassets/AppIcon.appiconset`, selected by the target as `AppIcon`. Press **Run** (⌘R) again to see it on the Home Screen. iOS may briefly cache the previous icon; if so, remove the app and reinstall it from Xcode.
3. **Technical identity:** keep the chosen **Bundle Identifier** stable after connecting App Attest and World ID. The backend's `PUPILLE_APP_ID` must use your Apple Team ID, a dot, and that exact bundle identifier.
4. **Version and launch screen:** the target currently uses Version `0.1`, Build `1`, and a blank launch screen. Change the Version and Build fields for later releases; the final launch screen should match the app's first screen. App Store description and screenshots are separate publishing information in App Store Connect, if you later distribute the app.

## World testing without an Orb

World's [IDKit integration guide](https://docs.world.org/world-id/idkit/integrate) and [Swift SDK testing notes](https://github.com/worldcoin/idkit-swift#testing) explicitly recommend the [World ID Simulator](https://simulator.worldcoin.org/) with `environment: .staging`. The simulator stands in for World App and offers test identities with a **Human** credential. It can complete staging proof requests without the tester obtaining a production Orb credential. World also documents a [simulator MCP](https://github.com/worldcoin/simulator#mcp-for-coding-agents) that completes native World ID 4.0 staging Proof of Human requests; test the actual iPhone/web simulator path before relying on that capability for the live demo. A staging proof is test infrastructure, not evidence that the tester personally visited an Orb.

The target production IDKit preset is [`proofOfHuman`](https://docs.world.org/world-id/idkit/credentials#proof-of-human). The full 4.0 session flow uses `allow_legacy_proofs: false`, because sessions cannot use legacy proofs. For the demo, try that same Proof of Human flow in staging. If the web simulator only completes the documented legacy flow, use `orbLegacy` in the **staging demo configuration only**, omit the per-post World session, and label the result `Staging Human (legacy Orb protocol)`. This still exercises an official staging proof and World server verification; it does not substitute the weaker Selfie Check credential.

### Short Developer Portal to-do

1. Sign in at [developer.world.org](https://developer.world.org/) and create a **staging World ID app** named Pupille. Enable/configure World ID 4.0 so the app has an `app_id` and an `rp_id`.
2. Create a World ID action with ID `pupille-profile-v1` for the one-profile-per-human proof. The app will request the `proofOfHuman` credential through IDKit.
3. Save the RP `signing_key` when the Portal shows it. Keep it in a backend-only secret store or local `.env`, never in Xcode, Git or chat. Do not rotate an existing key during setup.
4. Send me only the **public** `app_id`, `rp_id` and action ID, or tell me where you stored those public IDs locally. Then we can wire the real iPhone request and backend verification.

After Portal setup: generate the IDKit connector URL with staging environment; choose or create a simulator identity showing **Human**; complete the request in the simulator; forward the complete IDKit result unchanged to Pupille's backend; verify it through [`/api/v4/verify/{rp_id}`](https://docs.world.org/world-id/idkit/integrate#step-5-verify-the-proof-in-your-backend); check the returned environment and bind the verified nullifier to the profile. The backend needs durable replay protection before claiming one profile per test identity. The tester's linked identity URL `https://simulator.worldcoin.org/id/0x18310f83` showed no verified credentials when inspected, so select or create one with **Human** instead. The repository's existing World fixture remains a separate unit-test aid and must never appear as a verified World proof in the demo.

### Run the first live staging proof on the Mac

The standalone probe needs no Postgres and does not create a Pupille profile. Fill `backend/.env.world.local` with the RP signing key on your Mac only; the public app ID, RP ID, and action are already in that file. Git ignores the file. Then run `cd backend && npm run build && npm run world:probe` and open `http://127.0.0.1:8790` on the Mac. Click **Open World Simulator**, choose a simulator identity with **Human**, and approve the request. Keep the probe page open for its final `PASSED` or `FAILED` message. It requests IDKit 4.0 Proof of Human with `allow_legacy_proofs: false`, checks the action, nonce, environment, credential and signal hash, and forwards the unchanged result to World's verify API. Stop the probe with Ctrl-C. Each run makes a fresh request; do not share its connector URL because it contains an ephemeral encryption key.

The action description in the Developer Portal can be **Verify one human per Pupille profile**. This explains why Pupille requests the proof without implying that the staging simulator is a real Orb scan.

If the simulator shows **Presented** but the probe reports `environment_not_allowed`, check the app environment in the Developer Portal. A simulator proof uses `staging`; a production-only app/RP cannot verify it. Use the staging app's public `app_id` and `rp_id` and its own backend-only RP key in `.env.world.local`, then restart the probe to make a fresh request. Do not switch the proof to `production` to make a simulator test pass.

Apple references: [app target identity](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution), [icon assets](https://developer.apple.com/documentation/xcode/configuring-your-app-icon), [launch screen](https://developer.apple.com/documentation/xcode/specifying-your-apps-launch-screen).

Apple's current references: [Device Hub and pairing](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub), [run on a device](https://developer.apple.com/documentation/xcode/building-and-running-an-app), [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device), [App Attest environment](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.devicecheck.appattest-environment).

## Repo-specific setup for a real test

- The backend needs Node, `npm ci` in `backend/`, Postgres, `DATABASE_URL`, and `npm run migrate`. `npm run dev` starts the API on port 8787. A phone cannot use `localhost` to reach the Mac: use a reachable HTTPS deployment or the Mac's LAN address for early connectivity testing. For LAN HTTP, the iOS app needs an explicit App Transport Security development exception; use HTTPS for the World/App Attest flow.
- Set `PUPILLE_APP_ID` to **Apple Team ID + `.` + the app bundle identifier** used by Xcode. The backend's `test.pupille` default is only for fixtures. Real App Attest will fail if these differ.
- Do not set `PUPILLE_APP_ATTEST_TEST_ROOT_PEM` or `PUPILLE_WORLD_API_FIXTURE_MODE=1` for a real-device proof. Those are fixture-only switches.
- `backend/src/issuer.ts` currently creates a new certificate-signing key whenever the server starts. The iOS verifier needs a pinned public key, so the issuer key must be persisted before a durable end-to-end device demo.
- The live World verification response and Swift IDKit Proof of Human/session bindings have not been checked against a staging World ID proof yet. App Attest parsing **has** passed against this iPhone's genuine Apple attestation. Test the World flow with the exact error code and server log from each attempt.

## What to report when a step fails

Send the phone model and iOS version, the Xcode error text or screenshot, the selected signing Team and bundle identifier (not credentials), and which step failed: pairing, signing, launch, backend reachability, App Attest, World ID, camera, or publish. For API errors, include the HTTP status and JSON `error` field. Do not paste private keys or World proof payloads.
