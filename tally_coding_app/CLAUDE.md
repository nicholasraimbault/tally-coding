# Tally Coding App (Flutter)

Flutter app for the Tally Coding workspace runtime. Mobile (Android primary) + desktop (Linux primary, macOS/Windows supported).

## Design system

Brutal Terminal — JetBrains Mono everywhere, square corners, 1px hairlines, no gradients, no shadows, ANSI-mapped agent colors. Default theme: Tokyo Night. 28-theme picker under Settings → Appearance.

- Tokens: `lib/theme/tc_tokens.dart` (`TCTokens` ThemeExtension)
- Theme builder: `lib/theme/theme_builder.dart`
- 28-theme catalog: `lib/theme/theme_catalog.dart`
- Controller: `lib/theme/theme_controller.dart` (ChangeNotifier + SharedPreferences)
- Primitives: `lib/widgets/brutal/` (BrutalCard, BrutalBubble, BrutalProgressBar, BrutalButton, BrutalPill, TallyAvatar, AgentAvatar, CursorBlink)

Access tokens via `context.tc` (defined as an extension on BuildContext in `tc_tokens.dart`).

## Pinned versions

- Flutter SDK ^3.6.2
- material_ui / cupertino_ui — not yet adopted; using bundled Material with `useMaterial3: true` and custom TCTokens extension. Migrate when material_ui hits stable pub.dev.
- google_fonts ^6.2.1 (for JetBrains Mono)
- provider ^6.1.2 (ThemeController scope)
- shared_preferences ^2.5.5 (existing — theme + workspace persistence)

## Coding conventions

- New widgets that need theming MUST use `context.tc` — never hardcode colors.
- New widgets MUST use square corners (`borderRadius: BorderRadius.zero` or omit).
- New widgets MUST use 1px borders or no border — no shadows except iOS chrome.
- Active-state indicators use the shared `CursorBlink` widget (1.2s sharp on/off).
- Agent identity: use `AgentAvatar(role: AgentRole.{architect|coder|reader|tester})` — never construct manually.
- Tally identity: use `TallyAvatar()` — green block + T + cursor blink.

## Testing

- Unit + widget tests in `test/`.
- Golden tests for design-system primitives in `test/widgets/brutal/golden_test.dart` against Tokyo Night + Solarized Light. Regenerate with `flutter test --update-goldens`.
- Existing test patterns: `testWidgets('...', (tester) async { await tester.pumpWidget(MaterialApp(home: ...)); })`

## Dev workflow

- `flutter run -d linux` for desktop hot-reload during development.
- `flutter run -d <android-device-id>` for Android (use `flutter devices` to list).
- Agent-assisted dev: the Dart MCP server is installed (see `.mcp.json`); when you make a code change, run `flutter run` first so hot-reload auto-applies edits.

## Spec + design references

- Spec: `../docs/superpowers/specs/2026-05-22-ux-operator-journey-design.md`
- Plan (this sub-project): `../docs/superpowers/plans/2026-05-25-sub-project-b1-design-system-and-theme-picker.md`
- Visual reference: `../docs/design/claude-design/` (8 reference mockups + tc-shared.jsx)

## Widget previews

For visual iteration on the Brutal Terminal design system, use widget previews instead of running the full app:

```sh
cd tally_coding_app && flutter widget-preview start
# Opens a browser at http://localhost:<port> showing all *_preview.dart files
```

Preview files live alongside their widgets in `lib/widgets/`. Each preview wraps widgets in the Tokyo Night theme via `themeFromTokens(themeCatalog['tokyo-night']!.tokens)`. Compound widgets (EscalationSheet, AmbientMiniDash, kanban cards) include a "column overview" or "all variants" preview for at-a-glance coverage.

Current preview files:
- `lib/widgets/brutal/brutal_card_preview.dart` — BrutalCard (default, tappable, text, mixed content, 4-theme matrix)
- `lib/widgets/brutal/brutal_button_preview.dart` — BrutalButton (primary + outline, enabled + disabled, pair)
- `lib/widgets/brutal/brutal_progress_bar_preview.dart` — BrutalProgressBar at 0/30/50/75/100%
- `lib/widgets/brutal/tally_avatar_preview.dart` — TallyAvatar online/offline + sizes 18/22/28/38px
- `lib/widgets/brutal/agent_avatar_preview.dart` — All 4 AgentRole variants, active + inactive
- `lib/widgets/bottom_sheet/escalation_sheet_preview.dart` — EscalationSheet (2-option, 4-option stacked, queue badge, single)
- `lib/widgets/bottom_sheet/ambient_mini_dash_preview.dart` — AmbientMiniDash (empty, task rows, narrator, narrator+empty)
- `lib/widgets/kanban/kanban_card_previews.dart` — All kanban card types + column overview

Add new previews via the Flutter widget-previews skill (`.skills/flutter-add-widget-preview.md`).

## Agent skills

Official Flutter team skills are installed in `.skills/`. These ground agent sessions in framework best practices. Skills auto-discovered by Claude Code, Antigravity, and compatible agents.

| File | Use when |
|------|----------|
| `.skills/flutter-apply-architecture-best-practices.md` | Structuring new features or refactoring for scalability (MVVM + Repository pattern) |
| `.skills/flutter-add-widget-preview.md` | Adding `@Preview` annotations to new widgets |
| `.skills/flutter-add-integration-test.md` | Adding integration tests for user journeys |

Source: https://github.com/flutter/skills — fetched 2026-05-26. Run `npx skills update` to refresh.

## What B1 ships vs what's deferred

B1 ships the design system + theme picker. B2/B3/B4/B5 will rewire existing screens (discord_shell.dart, general_channel.dart, task_channel.dart, etc.) to use Brutal primitives — those screens will still look like the old Material-default app after B1 lands. That's by design: B1 is foundation.
