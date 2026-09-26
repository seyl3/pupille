# Pupille

Pupille is an iOS photo feed for ETHGlobal Tokyo's World track. A viewer can check that a photo's bytes have not changed and that the pseudonymous profile beside it signed the capture. No real name is shown.

The iPhone app has World-first onboarding, a camera, a public feed, emoji reactions, and social profiles with signed avatar uploads. Guests can browse the feed, open an author's public profile, and inspect each capture's checks. A signed-in developer can reset the local staging demo from Profile with Face ID. The app uses SwiftUI and Liquid Glass; the first version has no friends or messages.

## How verification works

1. **Identity:** A persistent Secure Enclave key belongs to a pseudonymous profile. World ID's Proof of Human signal binds the Human proof to that key and handle. Pupille's backend verifies the World result and issues a signed profile certificate. [Apple Secure Enclave](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/signing/privatekey) · [World IDKit](https://docs.world.org/world-id/idkit/integrate)
2. **Capture:** Pupille hashes the exact camera image, checks a fresh Apple App Attest assertion, and verifies the profile key's signature before storing the post and issuing a capture certificate. [Apple App Attest](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
3. **Viewing:** Each iPhone downloads the image and checks its hash, author binding, signature, and Pupille certificates locally before showing the verification badge.

The current native IDKit flow verifies World Human status at profile creation, not once per post. World ID sessions could later show that the same World ID returned to approve a post, but that needs a session linked to profile enrollment. [World session proofs](https://docs.world.org/world-id/idkit/session-proofs)

## What the badge means

The badge means the exact image passed Pupille's checks and the certified profile signed it. It cannot prove that the scene is true or who pressed the shutter. Apple and World evidence is checked by Pupille's backend; viewers check its signed certificates locally. Like [Succinct's ZCAM](https://github.com/succinctlabs/zcam1-sdk), Pupille separates image binding, app attestation, and verification.

## Current demo

Staging Human signup, publication, reactions, and guest viewing of a public profile have passed on real iPhones. The new in-app reset is covered by backend integration tests and still needs an on-device confirmation. Follow the [MVP iPhone guide](docs/IPHONE_MVP_TESTING.md) for setup and exact trust limits. The [follow-up list](docs/TODO.md) tracks remaining device checks, and the earlier [device testing guide](docs/IPHONE_TESTING.md) records checks already completed.
