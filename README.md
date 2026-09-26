# Pupille

**Portable photo provenance for World ID–verified humans.**

Pupille began as an iPhone photo feed for ETHGlobal Tokyo's World track. The app is a showcase for the underlying technology: a pseudonymous human signs a camera capture on an attested iPhone, and viewers can check the exact image bytes and the author's proof. We built the **Pupille SDK** so other apps can add that flow with a few API calls instead of rebuilding World ID onboarding, device attestation, camera signing, and verification.

The showcase app has World-first onboarding, a camera, public feed, emoji reactions, social profiles, and proof details on every post. The SDK packages the same protocol for other iOS apps and for verifiers outside Pupille. The original Pupille app still contains its own implementation; moving it onto PupilleKit is future work.

## What is in this repository

| Component | Purpose |
| --- | --- |
| [Pupille iOS app](ios/Pupille) | The full social showcase for the protocol. |
| [PupilleKit](sdk/ios/PupilleKit) | Swift package for World ID enrollment, the SDK camera, device signing, publishing, and local proof verification. |
| [@pupille/verify](sdk/verify) | Dependency-free TypeScript verifier for Node and browsers, plus the `pupille-proof` CLI. |
| [Web verifier](sdk/web-verifier) | Drop a proof-carrying JPEG onto a page and check it locally in the browser. |
| [SampleGram](sdk/ios/SampleGram) | A small second iOS app built only on PupilleKit's public API. |
| [Backend](backend) | Verifies World ID and Apple evidence, enforces one profile per Human proof, and issues signed profile and capture certificates. |

The [SDK guide](sdk/README.md) has the complete integration steps, protocol details, test commands, and demo script.

## From human proof to portable photo proof

1. **Enroll a human.** PupilleKit creates a Secure Enclave P-256 author key and an Apple App Attest key. Native World IDKit requests a Proof of Human bound to the profile key through a signal. The backend verifies the World result, prevents reuse of its action-scoped nullifier, and signs a profile certificate. [World IDKit](https://docs.world.org/world-id/idkit/integrate) · [Apple Secure Enclave](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/signing/privatekey)
2. **Capture and sign.** `PupilleCameraView` supplies the photo bytes. Publishing binds their SHA-256 hash to a fresh backend challenge, an App Attest assertion, and a Face ID–authorized signature from the author's Secure Enclave key. The backend rechecks those inputs and signs a capture certificate that includes the app ID. [Apple App Attest](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
3. **Verify anywhere.** The profile certificate, capture certificate, signature, and caption travel in an APP11 segment inside the JPEG. A verifier removes that segment, hashes the original camera bytes, and checks the proof using the issuer's public key. PupilleKit, the TypeScript package, and the web verifier all use this model; they do not trust a server-supplied “verified” flag.

The World proof happens **once at enrollment**, while the device signs each capture. A service that recompresses the JPEG may remove its embedded proof, so share the file itself when verification must travel with it.

## Add PupilleKit to an iPhone app

Add [`sdk/ios/PupilleKit`](sdk/ios/PupilleKit) as a local Swift package. Configure your backend, World app/RP IDs, the backend issuer's public key, and the App Attest app IDs you trust:

```swift
import PupilleKit

let client = PupilleClient(configuration: .init(
    backendURL: URL(string: "https://api.example.com")!,
    worldAppID: "app_…", worldRPID: "rp_…",
    issuerPublicKey: issuerPublicKey, // 32-byte Ed25519 public key
    trustedAppIDs: ["TEAMID.com.example.app"]
))
```

The host app calls the SDK for enrollment, capture, publishing, and verification:

```swift
let request = try await client.beginEnrollment(handle: "alice")
openURL(request.approvalURL)        // World App, or World Simulator in staging
_ = try await request.result()

PupilleCameraView { photo in captured = photo }
// In an async action, after unwrapping captured as photo:
let postID = try await client.publish(photo, caption: "Shibuya at dawn")
let posts = try await client.loadFeed() // each post has a verification result
let proofJPEG = try posts[0].shareableJPEG()
```

These are the calls made by the host's SwiftUI screens: `openURL` opens the World request, and `captured` stores the `CapturedPhoto` returned by the SDK camera. The host app needs camera and Face ID usage descriptions, its own App Attest configuration, a backend holding the World RP signing key, and a real iPhone for the hardware checks. See the [iOS quickstart](sdk/README.md#quickstart-ios) and [SampleGram's integration](sdk/ios/SampleGram/SampleGram/ContentView.swift).

## Verify a shared JPEG in TypeScript

The local [`@pupille/verify` package](sdk/verify) can check the file without calling Pupille's backend:

```ts
import { verifyFile, PUPILLE_ISSUER_PUBLIC_KEY } from "@pupille/verify";

const result = await verifyFile(jpegBytes, {
  issuerPublicKey: PUPILLE_ISSUER_PUBLIC_KEY,
  trustedAppIds: ["TEAMID.com.example.app"],
});
console.log(result?.verified, result?.checks);
```

The checks cover the World Human credential certified at signup, author binding, capture certificate, exact photo bytes, caption, capture commitment, author signature, and optionally the capturing app ID. To try the tests and browser verifier:

```sh
cd sdk
npm install
npm test
npm run verifier
```

To test a second app on an iPhone, run [`sdk/scripts/run-samplegram-backend.sh`](sdk/scripts/run-samplegram-backend.sh) and open [SampleGram](sdk/ios/SampleGram) in Xcode. The [SDK demo guide](sdk/README.md#running-the-samplegram-demo) covers its separate database, app ID, and World Simulator identity.

## What the badge means

The badge says that the **exact JPEG bytes** match a capture certified by Pupille's backend and signed by the device key of a World ID–verified profile. Viewers independently check the signed certificates, image hash, and author signature. Apple App Attest and World ID evidence are checked by the backend when the certificates are issued.

It does **not** establish that the depicted scene is truthful, that the account holder personally pressed the shutter, or that an uncompromised camera supplied every frame. A photo of a screen is still a camera photo. The current demo uses a **staging World Human identity**, not an Orb scan; production requires the appropriate World ID credential and configuration. See the [SDK trust model](sdk/README.md#what-the-badge-means-and-what-it-doesnt).

## Test the showcase app

Staging Human signup, publication, reactions, and guest viewing of public profiles have been exercised on real iPhones. Follow the [iPhone MVP guide](docs/IPHONE_MVP_TESTING.md) for setup, or the [device testing guide](docs/IPHONE_TESTING.md) for recorded checks. The [follow-up list](docs/TODO.md) tracks remaining work.
