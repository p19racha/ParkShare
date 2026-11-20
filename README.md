# ParkShare

ParkShare is an Android-first Flutter parking marketplace. The hosted pilot supports email and password accounts, parking discovery on a full-screen OpenStreetMap map, and publishing or managing real listings. Drag the parking sheet to browse results while keeping the map visible.

## Build and run

The Android build was prepared with Flutter 3.47.9 and Dart 3.13.7. Install Android Studio and the Android SDK command-line tools, and connect a device or start an emulator. Run `flutter doctor` to validate the host toolchain. Use the Android platform and NDK versions required by the installed Flutter SDK.

```sh
flutter pub get
flutter analyze
flutter run
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

The local release build uses the local debug signing key for sideloading. A build without configuration opens a setup screen. The map needs internet. For a connected build, copy `parkshare.defines.example.json` to `parkshare.defines.json` and fill in the public credentials. Use that file when you run or build the app.

```sh
flutter run --dart-define-from-file=parkshare.defines.json
flutter build apk --release --dart-define-from-file=parkshare.defines.json
```

### GitHub Releases

Push a version tag such as `v0.1.0` to run Flutter analysis and tests, build the Android APK, and attach `ParkShare-v0.1.0.apk` to [GitHub Releases](https://github.com/p19racha/ParkShare/releases). Downloads require access to the private repository.

The workflow reads `SUPABASE_URL` and `SUPABASE_ANON_KEY` from GitHub Actions repository variables. Use the Supabase publishable key or legacy anon key. It reads the base64-encoded pilot signing keystore from the `ANDROID_KEYSTORE_BASE64` repository secret. Keep using the same keystore for updates. It uses the Android debug-signing alias `androiddebugkey` and password `android` expected by the current Gradle configuration.

If the device already has a locally signed ParkShare APK, uninstall it before installing the first GitHub release. Android requires matching signing keys for in-place updates.

Optionally set `TILE_URL` in the defines file to a compatible raster tile endpoint. The default uses OpenStreetMap attribution and Flutter Map’s native HTTP-aware tile cache. See the [OSM tile usage policy](https://operations.osmfoundation.org/policies/tiles/).

## Deploy the hosted pilot

1. Create a dedicated free Supabase project. Install the Supabase CLI and authenticate locally. Run `supabase link --project-ref YOUR_PROJECT_REF`, `supabase db push`, and `supabase functions deploy market` from the project directory. The hosted catalog starts empty.
2. In **Authentication → Sign In / Providers → Email**, enable the email provider and turn **Confirm email** off. New signups receive a session directly. ParkShare asks for username, email, password, and password confirmation. [Supabase email auth settings](https://supabase.com/docs/guides/auth/general-configuration)
3. Copy the project URL and publishable key into `parkshare.defines.json` and build using the commands above. In Android Studio, add `--dart-define-from-file=parkshare.defines.json` to the Flutter run configuration's additional arguments. Keep service-role credentials in Supabase.
4. Run the configured build on Android. Sign in as one account, publish a space in Host, and browse that area as a second account. Verify that title edits appear and a paused space disappears. Relaunch to verify session restoration, then sign out and verify sign-in is required again.

For dashboard-only deployment, create an Edge Function called `market` via the editor and paste the entire `supabase/functions/market/index.ts` file. Disable the function's legacy JWT verification setting. The function validates the user's bearer token through Supabase Auth. If publishing reports that the parking service is missing, check that `market` appears in the same Supabase project as the Flutter config.

## Google sign-in on Android

1. In Google Auth Platform, create a Web application OAuth client. Set its authorized redirect URI to your Supabase project URL followed by `/auth/v1/callback`.
2. In Supabase **Authentication → Sign In / Providers → Google**, enable Google and save the OAuth client ID and secret. Keep the client secret in Supabase.
3. In Supabase **Authentication → URL Configuration → Redirect URLs**, add `com.parkshare.parkshare://auth-callback` exactly.
4. Run the configured Android build, tap **Continue with Google**, and use a Google account allowed by the consent screen. A new Google user chooses a username after returning to ParkShare. Existing users can still sign in with email and password.

[Supabase Google provider setup](https://supabase.com/docs/guides/auth/social-sign-in/auth-google) · [Supabase redirect allowlist](https://supabase.com/docs/guides/auth/redirect-urls)

## INR reservations and driving directions

For an existing hosted project, run `supabase/migrations/202611210001_inr_reservations.sql` once in the SQL Editor, then redeploy the updated `market` Edge Function. Keep legacy JWT verification off on that function. For a new project, apply the original marketplace migration before the INR migration.

- Edit existing listings in Host and set the hourly rupee price and entrance pin. Historical USD prices are preserved. Explore shows listings with an INR rate.
- Allow location while using the app. Explore centers on GPS at startup and displays a live location dot. Pan to browse another area or tap the location control to recenter.
- Choose a maximum stay and slide to confirm. A reservation holds the spot for 15 minutes to arrive. The driver can reopen directions from Trips, start the meter on arrival, and check out to see the INR amount. The pilot records the amount due for payment at the space.
- The full-screen map uses a driving route and updates its location and route estimates from GPS. `ROUTING_URL` can point to an authorized HTTPS OSRM driving route endpoint. The default FOSSGIS server is for light, non-commercial testing. Use an authorized routing service for commercial use. [OSRM service policy](https://map.project-osrm.org/about.html)

## Enable sandbox checkout later

The hosted listings pilot can run with just Supabase. To enable sandbox booking and payouts, add the Stripe configuration below and rebuild with a matching test publishable key.

1. Create a US Stripe platform in sandbox, enable Connect for Express accounts, and register a platform webhook at `https://YOUR_PROJECT_REF.supabase.co/functions/v1/market`. Subscribe to `payment_intent.amount_capturable_updated`, `payment_intent.succeeded`, `payment_intent.payment_failed`, and `payment_intent.canceled`.
2. Set `STRIPE_SECRET_KEY` (sandbox only), `STRIPE_WEBHOOK_SECRET`, and a long random `JOB_SECRET` in Supabase Edge Function secrets. Supabase supplies the service-role key and project URL. Only the Supabase publishable key and the Stripe `pk_test_` key go into the Flutter build. Connect onboarding returns to pages served by the deployed function. Optional HTTPS overrides are `CONNECT_RETURN_URL` and `CONNECT_REFRESH_URL`.
3. In Supabase Vault, create `parkshare_project_url` (project URL without trailing slash) and `parkshare_job_secret` (same value as `JOB_SECRET`). Run `supabase/setup/reconcile.sql` in the SQL Editor to schedule payment and occupancy reconciliation every minute. Check Cron history and Edge Function logs after enabling it.
4. In the app, sign in as the host, open **Host → Stripe onboarding**, and complete the sandbox form using Stripe test details. Return to Host and refresh status. Publish a listing with an approximate pin, rate and hours. Its exact address and gate instructions belong in the private field. Connected account proceeds follow Stripe's payout schedule, and the Host screen shows the latest payout records. Use Stripe’s test payout controls to verify payout states. [Stripe test documentation](https://docs.stripe.com/testing)

## Verify sandbox checkout

Run `supabase/tests/market.sql` as the database administrator in a sandbox. The test rolls back its changes. The Edge Function also supports static checking with `deno check --no-lock supabase/functions/market/index.ts`.

- Sign in on two devices or emulators as different drivers and reserve a host’s listing at the same time. One driver should get a payment hold. Verify the other device refreshes availability.
- In the winning session, use Stripe test card `4242 4242 4242 4242` with a future expiry and test CVC. Verify the ten-minute arrival countdown and that only the authorized driver can see private instructions. Start parking, relaunch the app, confirm the timer resumes, and check out. Verify one Stripe capture and destination transfer for the receipt amount, then verify the connected account payout status.
- Check a declined test card, expired payment hold, reservation no-show, cancellation, duplicate webhook delivery, and intermittent capture failure. The scheduler should release authorizations on expired or cancelled bookings and retry pending settlement.
- Test an overdue stay. Billing stops at the authorized limit, and the listing remains occupied until the driver checks out or the owner marks it clear. Change the device clock while parked and confirm the final bill still follows database timestamps.
