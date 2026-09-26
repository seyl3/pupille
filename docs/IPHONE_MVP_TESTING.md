# Pupille iPhone MVP test

## Run the Mac backend

Use the existing ignored `backend/.env.world.local` with the World RP key, RP ID, app ID, `PUPILLE_WORLD_ENVIRONMENT=staging`, and current staging verification token. Keep `backend/.secrets/issuer.pem`: its public half is pinned in the iPhone build, so replacing it makes existing posts appear unverified.

```sh
./tools/run-iphone-mvp.sh
```

The script starts the local PostgreSQL 17 instance, applies the schema, builds the backend, and serves port 8787. Keep its terminal open. The iPhone and Mac need the same Wi-Fi. In the app's **Development server** field, use `http://10.71.222.215:8787` for this Mac's current Wi-Fi address (update it if the address changes).

## Test on the iPhone

1. Open Pupille. The first screen is **Continue with World ID**. Choose a 3–20 character handle; the proof signal binds that handle to the iPhone's persistent Secure Enclave public key.
2. Tap **Verify and create profile**. Approve the profile signature with Face ID. The backend checks that signature and a fresh Apple App Attest assertion **before** the one-time World proof is requested. Then tap **Open World Simulator**, select a fresh Human staging identity, and approve. Switch back to Pupille. The backend checks the full IDKit result with World and stores the profile. A simulator identity already used for this action may be rejected as a duplicate.
3. Open **Capture**. Use the front/rear switch, flash control (rear camera), and 0.5×/1×/2× zoom when the lens is available, then press the circular shutter. Review the image and choose **Use photo** or **Retake**. Optionally add a caption, then tap **Publish verified capture**. The app sends exact camera bytes, a fresh App Attest assertion, and a Secure Enclave signature over the capture commitment. The backend checks them before saving the post.
4. Open **Feed** and pull down to refresh. Photos retain their full aspect ratio. The app downloads the image bytes and checks the image hash, issuer signatures, author binding, capture commitment, author signature, and caption hash. A green badge means those checks passed. The label shows whether the author used a staging or production Human proof at signup.
5. Open **Profile**, tap the avatar, and choose a photo. Face ID authorizes a one-time profile-key signature for the upload. The avatar is a chosen profile image, not a verified Pupille camera capture; relaunch and check that it persists. The profile shows your post count and your published photo grid.
6. After publishing, the Capture draft clears and a short success animation appears. On the Feed, tap a photo's green check or red X to see each verification result. Try the four reactions (🤓, ❤️, 🍆, 🇯🇵); each profile has one reaction per post and can change it.

For a second phone, tap **Explore verified feed** on the first screen. This lets an unsigned-in viewer inspect photos, tap an author's avatar or handle to view their public profile, and inspect cryptographic checks; publishing and reactions require a verified profile. The public simulator's [native World ID 4.0 proof service](https://github.com/worldcoin/simulator/blob/main/sidecar/src/routes.rs) auto-selects the first configured Human identity for a Proof of Human request and ignores its legacy browser identity selector. Creating a different browser identity or handle therefore does not supply a second distinct 4.0 Human nullifier for this action. A second verified profile needs another genuine staging 4.0 Human identity, such as one from an approved World ID Sandbox account.

## Reset the staging demo

Set `PUPILLE_ENABLE_DEMO_RESET=1` in the ignored `backend/.env.world.local` before starting the Mac backend. On an iPhone with a signed-in Pupille profile, open **Profile → Development → Reset demo from scratch**. Confirm deletion and approve with Face ID. The server removes all local demo profiles, World nullifiers, device registrations, photos, reactions, and pending challenges. The iPhone returns to the first screen so you can sign up again. Other iPhones using this backend should relaunch Pupille after the reset. The server URL, World RP configuration, and issuer key remain in place. This endpoint is disabled unless explicitly enabled on a staging backend, and it cannot run under `NODE_ENV=production`.

## What the badge means

For this build, World verifies **Proof of Human at profile creation**. Current native IDKit Swift exposes the 4.0 uniqueness request but not the public session flow, so posts rely on the World-bound profile key plus a fresh App Attest assertion; there is **no per-post World proof**. The camera path has no Photo Library import, but App Attest cannot prove the physical scene is truthful. A staging Human test identity is not a production Orb account.

Production uses the same app and RP with `PUPILLE_WORLD_ENVIRONMENT=production`, a production backend, the RP key in a server secret store, and an Orb verified World App user. The app chooses the IDKit environment reported by its backend and opens World App in production. Do not set fixture verification or a test App Attest root in production.

## Build and install again

Open `ios/Pupille/Pupille.xcodeproj`, select the connected iPhone 14 Pro (`gateway`), and press **⌘R**. The app name is `Pupille` in `Info.plist`. The Home Screen icon uses `pupille-logo.png`; in-app decorative marks use `pupille-icon.svg`.
