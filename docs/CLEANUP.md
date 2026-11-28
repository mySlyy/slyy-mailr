# Cleanup backlog

Redundant code found by `slyy-analytics` (repeated blocks, unused declarations) and checked by hand on 2026-11-28.
Each item was marked in the code with `// CLEANUP(Cn)`; all markers are gone now (`grep -rn "CLEANUP(" App Packages` finds nothing).

**Status: all items done (2026-11-28).** Lines of code (`slyy-analytics`): 12,013 → 11,539 production, 2,237 → 2,122 test.

| # | What | Done |
|---|---|---|
| C1 | OAuth sign-in flow unused by the app (Google signs in with an app password) | Removed `OAuthProvider`, `OAuthTokens`, `OAuthError`, `OAuthTokenStore`, PKCE/SHA-256, `OAuthCallbackReceiver`/`OAuthSignIn` and their tests. XOAUTH2 SASL in IMAP/SMTP (`oauth:`, `AccountSettings.usesOAuth`, `MailService` token source) stays, in `Account/XOAUTH2.swift`, with its tests. Microsoft sign-in can restore the flow from git (commit before this cleanup). |
| C2 | `AppModel.sample()` test fixture shipped in the app | Moved to `App/Tests/SampleModel.swift`. The app keeps a small test seam (`AppModel.offline(...)`, `setSampleAccount`, `showForTesting`) because the model's state is `private(set)`. |
| C3 | Cleanup of the pre-rename "Slyy Mail.app" and old installer names | Removed the "Slyy Mail.app" (ai.slyy.mail) removal, the `slyy-mail-` installer and "Slyy Mail …" volume rules, and the two read-write temporary-exception entitlements. Kept: cleanup of current Slyy Mailr DMGs in Downloads and mounted "Slyy Mailr …" volumes (`/Volumes/` read-only exception) and Sparkle's mach-lookup exception. Old `slyy-mailr-…-mac-universal.dmg` files are still trashed by the generic version rule. |
| C4 | `probe()` repeated `connect()`'s open, greeting and STARTTLS | One private `IMAPClient.openSession()`. |
| C5 | Primary and Accent button styles identical except colours | One `SlyyFilledButtonStyle(fill:pressed:)` with `.slyyPrimary(...)` / `.slyyAccent(...)`. |
| C6 | Header-bar padding (`topInset`) repeated | `View.headerBar(iOSTop:bottom:)` in Theme.swift. |
| C7 | Calendar on/off toggle list repeated | `CalendarToggle` view (AccountViews.swift). |
| C8 | Keychain base query built three times | `Keychain.baseQuery(_:)`. |
| C9 | Event form rows repeated label/picker layout | `fieldRow(_:control:)` in EventViews.swift. |
| C10 | Unused or test-only code | Removed `openAttachment` and `HavenClient.requestGrants`; `MailService.rawMessage` moved into the tests (AliasTests.swift). `KnownProvider.needsAppPassword` now decides, via `SignInError.appPasswordProvider`, when Settings → Account shows the Gmail app-password guide after a refused login. |
| C11 | OAuth tests named after Yahoo | XOAUTH2 tests use example.com addresses (the KnownProvider test still checks that Yahoo is not special-cased). |

Not redundant (looked similar, checked): `ICalText.escape` vs `MessageBody.escape` (iCalendar vs HTML escaping); Sparkle driver
callbacks in UpdateWindow, UIKit/AppKit delegate methods, `CalDAVClient.deleteCalendar` (test harness needs it).
