# slyy-analytics

Code analytics for Slyy products. Python 3 standard library only; no installs.

| Analysis | What it reports |
|---|---|
| size | lines of code/comment/blank per module and language, largest files, longest functions, flags over thresholds |
| history | size at every release tag (from git, no checkout), commits and lines changed per week |
| coverage | reads an llvm-cov JSON export or LCOV file: percent per module, least-covered files |
| deps | locked and declared packages (SwiftPM, npm, Cargo), CI actions and whether they're pinned to a commit |
| security | entitlements, transport security exceptions, workflow triggers/permissions/secrets, secret-like text |

## Use in a product

1. Add `analytics.json` at the repo root: `project`, `modules` (name, paths, kind: code/test/tooling/docs/resources/web), optional `exclude`, `coverage.file`, `dependencies.declared_in`, `security.entitlements_in`, `thresholds`, `history.tags`.
2. Run:

```sh
PYTHONPATH=Tools/slyy-analytics python3 -m slyy_analytics --config analytics.json   # build/analytics/analytics.json + REPORT.md
PYTHONPATH=Tools/slyy-analytics python3 -m slyy_analytics.export                    # build/analytics/dash/*.json ({rows, meta}) for a dashboard
```

`--skip history,coverage` leaves out analyses. Coverage for Swift: `swift test --enable-code-coverage`, then copy `.build/<triple>/debug/codecov/<Package>.json` to the configured file. A hand-written `build/analytics/review.json` (code-review findings) is exported too when present.
