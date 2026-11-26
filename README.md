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

Push a tag `vX.Y.Z`. CI builds the universal DMG, creates a GitHub release here and — when the
`RELEASES_TOKEN` secret (contents:write on mySlyy/releases) is set — publishes it to
<https://github.com/mySlyy/releases>. Developer ID signing and notarization run when the
`MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD` secrets are set.

iOS builds need an Apple Developer team for TestFlight; CI only compile-checks iOS.

## Security notes

- Passwords live in the Keychain; the core refuses to log in if STARTTLS is configured but not offered.
- HTML mail renders with JavaScript off, a non-persistent web store and a CSP that blocks all remote loads until "Load images".
- Jitsi rooms on vid.rocket.re-cloud.io are open (no auth on the server), so room names are random 20-character slugs. Enabling JWT auth on the Jitsi server is recommended.
