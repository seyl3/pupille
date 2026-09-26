# Amazon review demo

A mock store app (demo only, not affiliated with Amazon) with one feature: **photo reviews that prove a real person took the picture**, so review photos can't be faked with stock images or AI.

- No store account. Tapping **Write a customer review** on an unverified iPhone opens **Continue with Pupille**: one Face ID prompt and one World ID Proof of Human. That screen is the whole integration from the store's side. After that, Face ID signs each photo.
- The only photo source is PupilleKit's camera. Face ID signs the exact bytes on the iPhone, and the backend checks a fresh Apple App Attest assertion.
- The rating, headline and text are stored in the signed caption, so editing a review breaks its badge too.
- Each review shows **Verified Human Photo**. Tap it, or the photo, for the checks, which run on the phone.

All provenance calls are in `Store.swift` (`signIn`, `submit`, `loadReviews`); the rest is UI. The app icon is an original design, not Amazon's logo.

## Run it

1. Start the backend for this app: `sdk/scripts/run-samplegram-backend.sh` (port 8789, App Attest ID `4397GAXGZ4.app.pupille.sample`).
2. Open `sdk/ios/Amazon/Amazon.xcodeproj`, choose a real iPhone and run. App Attest and the Secure Enclave don't work in the Simulator.
3. At the bottom of the product page, open **Development backend** and enter `http://<your Mac's IP>:8789`.
4. Tap **Write a customer review**, then **Continue with Pupille**. Approve Face ID, then the Proof of Human in World Simulator, and come back to the app.
5. Pick stars, write a headline and a review, take a photo, **Submit**. Face ID signs the photo, and the review appears with **Verified Human Photo**.

**Sign out** under the review button forgets this iPhone's keys, so you can show the sign-in step again.

To build under another Apple team, change the team and bundle ID in Xcode, then use the new `TEAMID.bundle.id` for `PUPILLE_APP_ID` in the backend script and for `trustedAppIDs` in `Store.swift`.
