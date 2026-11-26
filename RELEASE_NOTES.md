Slyy Mailr 0.2.0 — Slyy design and bug fixes

**New look**: the app now follows the Slyy wireframes — Hanken Grotesk and Martian Mono, square
controls, the blue accent, hairline borders. New layouts for mail, compose, calendar, the meeting
editor, sign-in and the video call window; iPhone gets the Mail / Calendar / Settings tab bar.

**Fixed**
- Sign-in for slyy.ai: server settings are found via the domain's MX host (autoconfig.slyy.ai has a
  wrong certificate, and imap.slyy.ai is the web server). The calendar is found on the mail server.
- Hangs and missing or mixed-up mail when several things loaded at once (list refresh, opening a
  message, new-mail push).
- Sign-in no longer waits 30 minutes on an unresponsive server; errors say what to check.
- New-mail push (IDLE) is no longer cut after 30 seconds on Mac/iPhone.
- Invitations are marked in the message list; video links are a card in compose.

**Install (macOS)**: open the DMG and drag Slyy Mailr to Applications. Signed with Developer ID and
notarized by Apple.
