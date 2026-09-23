# Dream Language iOS OAuth repair

Status: implementation prepared; web companion deployment, Apple provisioning, and physical-device validation are release prerequisites. This is not a verified App Review build.

Delivery: prepared for review on a dedicated GitHub branch. Repository access was restored on 23 September 2026 by installing the authorized Codex Connector for the two selected repositories. No deployment or device validation has been performed.

## Verified evidence (22 September 2026)

- iOS base: `c10797634d38c7384efa69cdfe07d05fee52c5d0`, repository `lukaspomp-ui/dream-language-ios`.
- The wrapper registered IAP handlers but no `oauth-signin`; URL schemes were empty; Sign in with Apple was absent. `WKAppBoundDomains` incorrectly included `/dashboard`.
- The inspected Lovable `src/lib/nativeAuth.ts` sends `{provider, redirect_uri}` and listens for `oauth-result`, with a 180-second timeout. `Auth.tsx` supplies `https://dream-language.lovable.app/auth/callback` and calls `supabase.auth.setSession(tokens)` after the native result. `/auth/callback` is an unguarded React route.
- Lovable's Git settings identify `lukaspomp-ui/Dream-Language`, branch `main`. Access was restored on 23 September 2026. The current nativeAuth.ts and Auth.tsx were verified against commit 9587b2366a6484655f3f9f8c4710040a046e91b6; the companion changes are proposed separately for that repository.
- The downloaded production bundle lacked the bridge strings and callback route. Lovable showed unpublished changes. Later unrelated SEO changes also appeared in the project; these were not edited by this task. Review the complete publish diff before deploying.
- Live broker rejected `app.lovable.dream-language://oauth/callback` as `redirect_uri is not allowed`. With the HTTPS relay URL, the Google probe reached that callback path (currently a 404 SPA fallback); Apple reached `appleid.apple.com/auth/authorize`. This verifies acceptance of the redirect, not completion of either native login.
- The Apple authorization request used client ID `dev.lovable.managed-auth` and provider callback `https://oauth.lovable.app/callback`. No private keys, team IDs, or Google client IDs were inferred or changed.
- Codemagic currently strips push and associated-domain entitlements. This patch uses a custom-scheme return from an HTTPS relay and does not depend on universal links or an invented Apple Team ID.

## Implemented flow

1. The trusted top-level app page sends `oauth-signin` with Google or Apple and its normal `/auth/callback` URL.
2. Native code validates the request, creates 256 bits of random state, retains an `ASWebAuthenticationSession`, and requests the existing `/~oauth/initiate` endpoint.
3. For this native session only, `redirect_uri` is the new HTTPS `/auth/native-callback.html?native_state=...` relay. Browser-only authentication continues using `/auth/callback` unchanged.
4. The relay is a standalone static document with no Supabase client, React, storage, analytics, or network requests. It checks state, removes credentials from browser history, and returns only the expected values to `app.lovable.dream-language://oauth/callback`.
5. Native code checks callback scheme/host/path and state, rejects duplicates/missing tokens, and dispatches `oauth-result` with structured `callAsyncJavaScript` arguments. Origin and initiating-document checks protect delivery across navigations.
6. The existing web layer establishes its own Supabase session. Native timeout is 170 seconds, ahead of the 180-second web timeout; cancellation and failure clear native state.

The URL scheme is a newly introduced app-owned configuration derived from the existing bundle ID `app.lovable.dream-language`; it is not an existing provider setting. The new HTTPS path must be deployed before testing.

## Changed files

In iOS:
- `src/Dream Language/OAuthBridge.swift` (new): session lifecycle, secure callback parsing and event delivery.
- `src/Dream Language/ViewController.swift`: handler dispatch and cancellation on page navigation.
- `src/Dream Language/WebView.swift`: handler registration, document marker, exact host matching, prevention of OAuth fallback into WKWebView/Safari.
- `src/Dream Language/SceneDelegate.swift`: ignore unsolicited/cold-start OAuth URLs instead of converting them to HTTPS.
- `src/Dream Language/Info.plist`: scheme registration and corrected app-bound domain.
- `src/Dream Language/Entitlements/Entitlements.plist`: Sign in with Apple entitlement.
- `src/Dream Language.xcodeproj/project.pbxproj`: compile bridge and enable capability.

Required in web repository (prepared under `web-companion/`):
- `public/auth/native-callback.html` and `public/auth/native-callback.js` (new).
- `src/lib/nativeAuth.ts`: prevent overlapping requests, validate result shape and clean up listeners.
- `src/pages/Auth.tsx`: clear the 20-second web watchdog immediately upon entering the native branch. The native timeout covers the system sheet, where normal user sign-in can take more than 20 seconds.

Supporting files: `web-companion/apply.mjs`, `tests/oauth-web.test.cjs`, this report. IAP, subscriptions, Firebase, unrelated UI and Codemagic publishing settings were not changed.

## Apply and deploy the web companion

From a checkout with access to the web repository:

```sh
node /path/to/dream-language-ios/web-companion/apply.mjs /path/to/Dream-Language
```

Review that only the four web paths above changed, run the repository's typecheck/build/tests, and sync to Lovable. Publish the auth changes and static relay before installing the new iOS build. The full web repository was not available locally for its build/typecheck in this session.

Verify `https://dream-language.lovable.app/auth/native-callback.html` serves the standalone “Return to Dream Language” document, not the React 404 fallback, and `/auth/native-callback.js` serves the relay. Confirm hosting does not inject analytics or third-party scripts into the relay. Check that a prior service worker does not intercept the relay with an old SPA shell; exclude `/auth/native-callback.html` from any navigation fallback/cache rules if necessary. A clean installation alone does not clear Safari's website data.

Google/Apple/Lovable authentication pages are allowed within the system authentication session, not added to `WKAppBoundDomains`. Google disallows OAuth in developer-controlled embedded user agents. Direct legacy OAuth navigation in WKWebView now shows an update error instead of silently leaving the app.

## Checks completed in this session

`node --test --test-isolation=none tests/oauth-web.test.cjs`: 14 passed, 0 failed. Covers token encoding, query/fragment responses, missing/wrong/duplicate state, duplicate tokens, partial sessions, provider errors, origin/frame restrictions, fixed callback destination, concurrency, timeout, cancellation and listener cleanup. These tests execute the web relay and TypeScript bridge with a simulated browser; they do not execute UIKit or ASWebAuthenticationSession.

XML parsing and assertions for the app-bound domain, registered callback scheme and Apple entitlement passed. `git diff --check` passed. Node stripped the bridge's TypeScript syntax to execute tests; this is not a full TypeScript typecheck. The initial test runner could not spawn a child process in the sandbox; the supported same-process runner completed successfully.

## Apple Developer / Xcode steps

1. In Certificates, Identifiers & Profiles, find the existing App ID for `app.lovable.dream-language`; enable Sign in with Apple. Use the actual team that owns this App ID.
2. Regenerate/refresh the App Store provisioning profile so it contains `com.apple.developer.applesignin = [Default]`. Make sure Codemagic fetches the refreshed profile rather than reusing an incompatible cached profile.
3. In Xcode, open `src/Dream Language.xcworkspace`, target Dream Language, Signing & Capabilities. Verify the actual development team, bundle ID, Sign in with Apple, and Debug/Release entitlements. No Team ID has been set by this patch.
4. The live Apple provider is Lovable's managed Service ID. Adding native capability does not switch the web provider to your own Apple Service ID or change the “Lovable” consent-screen name. Confirm the intended managed-provider setup in Lovable; if switching to your own provider, obtain the actual Service ID, key and return URL from the owning Apple/Lovable configuration. Keep secrets out of the repo.
5. Increase the build number, install CocoaPods, clean and archive. Existing Codemagic release workflow publishes to TestFlight when run; it was not triggered here.

On a Mac:

```sh
cd src
pod install
xcodebuild -workspace "Dream Language.xcworkspace" -scheme "Dream Language" \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Then archive Release with valid signing. Inspect the signed archive's entitlements, not only the source plist. Xcode/Swift SDK compilation, signing, archive and native runtime tests were unavailable on this Windows host.

## Clean-install acceptance test before App Review

Use a physical supported iPhone; include the reviewer device/OS combination where available, and the minimum supported iOS 15 device if support is retained. Test iPad as well if the app is distributed to it.

1. First publish the web companion and existing Lovable auth changes; confirm relay responses as above. Install the new signed build through TestFlight or Xcode. Record app version/build, device and OS.
2. Log out, delete all prior Dream Language installations, reinstall, and confirm the login screen appears. For a fresh provider-consent scenario use a designated test account or reset that test account's provider consent. Deleting the app does not necessarily remove Safari/provider sessions or Keychain credentials.
3. Tap Google once. Verify an iOS system authentication sheet opens, complete login, and verify it dismisses back into Dream Language with the correct account on the dashboard. No Safari app switch, blank page, 404, or login loop. Access an authenticated feature to prove the WebView session exists.
4. Force-quit and relaunch: the same account remains signed in. Log out and sign in again. Wait more than 20 seconds on the provider screen before completing once, to confirm the old watchdog no longer fires.
5. Log out, delete/reinstall again, and repeat steps 3–4 for Apple. Test Hide My Email and a returning Apple account when applicable.
6. For both providers: cancel the sheet and retry; interrupt connectivity and restore it; allow the 170-second native timeout and retry; attempt a quick second tap. There must be one active native flow, a usable error/cancel result, and no late success from an expired attempt.
7. While a login is pending, reload/navigate the app page, then complete/cancel the sheet. No credentials should be delivered to a replacement document. Open an unsolicited custom callback while the app is terminated: it must start normally without logging in from that link.
8. Inspect debug logs only for status/errors; never record full callback URLs, access or refresh tokens. Confirm each successful login's account and backend session. Record pass/fail for each provider, cold launch and cancellation.
9. Only after the signed build passes, submit it to App Review with accurate review instructions. The previously reported expired-subscription demo account and Support URL are separate review requirements and are outside this OAuth patch.

## References

- https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/
- https://developer.apple.com/documentation/xcode/configuring-sign-in-with-apple
- https://webkit.org/blog/10882/app-bound-domains/
- https://developers.google.com/identity/protocols/oauth2/policies
