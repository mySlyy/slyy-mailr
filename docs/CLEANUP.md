# Cleanup backlog

Redundant code found by `slyy-analytics` (repeated blocks, unused declarations) and checked by hand on 2026-11-28.
Each item is marked in the code with `// CLEANUP(Cn)`: `grep -rn "CLEANUP(" App Packages`. Remove the marker with the fix.
Line counts are estimates of what the fix removes.

| # | What | Where | Fix | ~Lines |
|---|---|---|---|---:|
| C1 | OAuth sign-in flow unused by the app (Google signs in with an app password) | Account/OAuth.swift, OAuthCallbackReceiver.swift + OAuthTests | **Decision:** keep for Microsoft sign-in, or remove now and restore from git later | 360 (+ ~280 test) |
| C2 | `AppModel.sample()` test fixture ships in the app | AppModel.swift | Move to App/Tests with `setSampleAccount` | 100 |
| C3 | Cleanup of the pre-rename "Slyy Mail.app" and universal (Intel) DMGs | InstallerCleanup.swift, project.yml entitlements, AppTests | Remove once 0.2.x installs are gone; drops two temporary-exception entitlements | 80 |
| C4 | `probe()` repeats `connect()`'s open, greeting and STARTTLS | IMAPClient.swift | One private `openSession()` | 10 |
| C5 | Primary and Accent button styles identical except colours; unused `.slyyPrimary` shortcut | Theme.swift | One filled style taking fill/pressed colours | 15 |
| C6 | Header-bar padding (`topInset`) repeated | CalendarView, MessageDetailView, MessageListView | Shared view modifier | 15 |
| C7 | Calendar on/off toggle list repeated | SidebarView, AccountViews | `CalendarToggle` view | 10 |
| C8 | Keychain base query built three times | Keychain.swift | `baseQuery(account)` | 8 |
| C9 | Event form rows repeat label/picker layout | EventViews.swift | `FieldRow` helper | 15 |
| C10 | Unused or test-only: `openAttachment`, `HavenClient.requestGrants`, `KnownProvider.needsAppPassword`, `MailService.rawMessage` | MessageDetailView, HavenClient, KnownProviders, MailService | Remove; wire `needsAppPassword` into the app-password guide instead | 25 |
| C11 | OAuth tests still named after Yahoo, which was dropped | OAuthTests.swift | Rename to a neutral example provider | 0 |

Not redundant (looked similar, checked): `ICalText.escape` vs `MessageBody.escape` (iCalendar vs HTML escaping); Sparkle driver
callbacks in UpdateWindow, UIKit/AppKit delegate methods, `CalDAVClient.deleteCalendar` (test harness needs it).
