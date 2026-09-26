# Pupille

Pupille is a photo app where people can check and cryptographically verify that a picture has not changed and that it was published by the pseudonymous profile shown beside it. Take a photo, post it to a public feed, and tap its badge to see the evidence. No real name is shown.

The native iPhone app has a global feed, camera, and personal profile. Its black-and-white interface uses SwiftUI and Liquid Glass. There are no friends or messages in the first version.

## How verification works

1. **Identity:** A Secure Enclave key signs posts for `@xyz`. World ID's **signal** binds a human verification to that profile key and nickname. Pupille certifies the link. A separate passkey could handle login or recovery. [Apple Secure Enclave](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/signing/privatekey) [World IDKit](https://docs.world.org/world-id/idkit/integrate)
2. **Capture:** Pupille hashes the photo. App Attest binds that hash and a fresh challenge to a genuine app instance; the profile key signs it too. The server checks the evidence and issues a certificate. [Apple App Attest](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
3. **Viewing:** Each iPhone checks the downloaded photo, profile signature, and Pupille certificates locally before showing the badge.

World ID **sessions** may later show that the same World ID returned to approve a post. That requires a session linked to profile enrollment; an unrelated second proof is insufficient. [World session proofs](https://docs.world.org/world-id/idkit/session-proofs)

## What the badge means

A badge means the exact image passed Pupille's checks and the certified profile signed it. It cannot prove that the scene is true or who pressed the shutter. Apple and World evidence is checked by Pupille's server; viewers check its signed certificate locally.

Like [Succinct's ZCAM](https://github.com/succinctlabs/zcam1-sdk), Pupille separates image binding, app attestation, and verification. 
