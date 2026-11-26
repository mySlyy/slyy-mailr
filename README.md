# Slyy Mailr

Native (Swift/SwiftUI) replacement for Outlook on our own infrastructure:

- **Mail** over our IMAP/SMTP servers (TLS or STARTTLS), push via IMAP IDLE.
- **Calendar** over CalDAV with invitations that work with Outlook, Google and Apple (iTIP/iMIP).
- **Video calls** on Jitsi Meet at <https://vid.rocket.re-cloud.io>, one click from events, mails and reminders.

Platforms: macOS 14+ (universal DMG) and iOS/iPadOS 17+.

## Layout

| Path | What |
| --- | --- |
| `Packages/SlyyMailKit` | Platform-independent core: IMAP, SMTP, MIME, iCalendar/RRULE/iTIP, CalDAV, Jitsi, services. Builds and tests on macOS and Linux. |
| `App/Sources` | SwiftUI app shared by macOS and iOS. |
| `project.yml` | XcodeGen spec (`xcodegen generate` → `SlyyMail.xcodeproj`). |
| `Tools/dev-servers` | Local Dovecot/SMTP/Radicale setup for integration tests. |
| `.github/workflows/build.yml` | CI: tests, macOS + iOS builds, DMG, releases on `v*` tags. |

## Build

```sh
brew install xcodegen
xcodegen generate
open SlyyMail.xcodeproj          # schemes: SlyyMail-macOS, SlyyMail-iOS
```

Core tests: `swift test --package-path Packages/SlyyMailKit` (add `SLYY_IT=1` with the dev servers running).

## Release

Every push to `main` builds and tests. When `MARKETING_VERSION` in `project.yml` has no release yet,
CI creates `v<version>` with the DMG, and publishes `mailr-v<version>` to
<https://github.com/mySlyy/releases> when `RELEASES_TOKEN` is set.

Repository secrets:

| Secret | What |
| --- | --- |
| `MACOS_CERT_P12` | base64 of the Developer ID Application `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERT_PASSWORD` | its password |
| `ASC_KEY_P8` | App Store Connect API key: the `.p8` text (or its base64) |
| `ASC_KEY_ID` | the key id (the `XXXX` in `AuthKey_XXXX.p8`) |
| `ASC_ISSUER_ID` | issuer id (App Store Connect → Users and Access → Integrations); only for Team API keys, leave unset for Individual keys |
| `RELEASES_TOKEN` | fine-grained token with contents:write on mySlyy/releases |

With the first four set, CI signs the app with the hardened runtime, notarizes and staples the DMG.
To notarize a DMG by hand on a Mac: `Tools/release/notarize-local.sh <dmg> <p12> <p8> <key id> <issuer id>`.

iOS builds need an Apple Developer team for TestFlight; CI only compile-checks iOS.

## Security notes

- Passwords live in the Keychain; the core refuses to log in if STARTTLS is configured but not offered.
- HTML mail renders with JavaScript off, a non-persistent web store and a CSP that blocks all remote loads until "Load images".
- Jitsi rooms on vid.rocket.re-cloud.io are open (no auth on the server), so room names are random 20-character slugs. Enabling JWT auth on the Jitsi server is recommended.
