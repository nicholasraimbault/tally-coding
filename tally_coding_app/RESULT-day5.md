# Day 5 — Flutter App Scaffold

**Status: PASS** (analyze clean, 1/1 test passing)

## What was scaffolded

`flutter_app/` (Flutter 3.27.4, Dart 3.6.2) targeting linux, macos, windows,
android, ios. Renamed to `tally_coding_app` (org: `com.tallycoding`).

```
tally_coding_app/
  lib/main.dart           — TallyCodingApp placeholder (Material 3, dark seed)
  test/widget_test.dart   — Verifies placeholder taglines render
  pubspec.yaml            — skytale_sdk pinned to skytale#dart-sdk-skeleton (PR #469)
  android/ ios/ linux/ macos/ windows/
```

## Dependencies wired

| Package | Source | Purpose |
|---|---|---|
| `flutter` | SDK | Framework |
| `cupertino_icons` | pub.dev | iOS icons |
| `skytale_sdk` | git: `nicholasraimbault/skytale#dart-sdk-skeleton` (sdk/dart) | E2E encryption + agent identity (skeleton) |
| `flutter_test` | SDK | Test runner |
| `flutter_lints` | pub.dev | Recommended lints |

Convex (state sync) and Clerk (auth) deferred to the sprint that wires actual
agent UI — the skeleton today only proves the build chain works end-to-end.

## Verification

```bash
cd ~/Projects/pronoic/tally-coding/tally_coding_app
flutter pub get   # 8 deps resolved, including skytale_sdk from git
flutter analyze   # No issues found! (ran in 2.8s)
flutter test      # 1/1 passing — placeholder shows stack tagline
```

## Skytale SDK note

The git dependency on `dart-sdk-skeleton` is a temporary pin until PR #469
merges to skytale master. When it does, swap the `git:` block for a pub.dev
or path-based reference.

## Run locally

```bash
flutter run -d linux    # or macos / chrome / etc.
```

Confirms Material 3 dark theme + tagline copy renders. Agent UI lands next
sprint.
