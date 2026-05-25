# Sub-Project B1 — Brutal Terminal Design System + Theme Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Translate the Brutal Terminal design system (tc-shared.jsx) into a Flutter package of widget primitives + ThemeData + a ChangeNotifier-backed theme controller, then ship a Settings → Appearance theme picker with a 28-theme curated catalog (default: Tokyo Night).

**Architecture:** Token-based design system using Flutter's `ThemeExtension` API (`TCTokens`). Each theme = an instance of `TCTokens`; `themeFromTokens(tokens)` constructs a `ThemeData` with the extension attached. A `ThemeController` (ChangeNotifier) holds the active theme slug, persists to SharedPreferences, and rebuilds the app tree on change. Brutal widget primitives (`BrutalCard`, `TallyAvatar`, `AgentAvatar`, `BrutalProgressBar`, `BrutalBubble`, `BrutalButton`, `BrutalPill`, `CursorBlink`) read tokens via `Theme.of(context).extension<TCTokens>()!`. Theme picker lives at Settings → Appearance (new tab on `workspace_settings.dart`).

**Tech Stack:**
- Flutter SDK ^3.6.2 (existing pubspec)
- Material 3 / `useMaterial3: true` (existing; we override token-relevant defaults via `TCTokens`)
- `google_fonts: ^6.2.1` (new — for JetBrains Mono via `GoogleFonts.jetBrainsMono()`)
- `shared_preferences: ^2.5.5` (existing — theme persistence)
- `provider: ^6.1.2` (new — for ThemeController; lightweight, matches existing patterns)
- Standard `flutter_test` for unit + widget tests
- Built-in `matchesGoldenFile` for golden tests across themes

**Scope boundary:** B1 ships the design system + theme picker as a foundation. It does NOT yet rewire existing screens (`discord_shell.dart`, `general_channel.dart`, etc.) to use Brutal primitives — that's B2/B3/B5's job. B1's acceptance: theme picker works, primitives render correctly across 28 themes, ThemeData is wired into `main.dart`, but old widgets continue to look the way they do today (they'll be refactored in subsequent sub-projects).

---

## File Structure

### Create

| Path | Responsibility |
|---|---|
| `tally_coding_app/lib/theme/tc_tokens.dart` | `TCTokens` ThemeExtension + token type definitions |
| `tally_coding_app/lib/theme/theme_builder.dart` | `themeFromTokens(TCTokens)` → ThemeData factory |
| `tally_coding_app/lib/theme/theme_catalog.dart` | `themeCatalog`: const Map<String, TCTokens> for all 28 themes |
| `tally_coding_app/lib/theme/theme_controller.dart` | `ThemeController` ChangeNotifier + SharedPreferences persistence |
| `tally_coding_app/lib/theme/theme.dart` | Barrel export (`tc_tokens`, `theme_builder`, `theme_catalog`, `theme_controller`) |
| `tally_coding_app/lib/widgets/brutal/cursor_blink.dart` | Shared 1.2s on/off blink animation |
| `tally_coding_app/lib/widgets/brutal/brutal_card.dart` | 1px border + square + hover state |
| `tally_coding_app/lib/widgets/brutal/brutal_bubble.dart` | Tally narration container (1px border, square, max-width) |
| `tally_coding_app/lib/widgets/brutal/brutal_progress_bar.dart` | Solid fill on border track, square |
| `tally_coding_app/lib/widgets/brutal/brutal_button.dart` | Primary (solid fill) + outline variants |
| `tally_coding_app/lib/widgets/brutal/brutal_pill.dart` | 1px border + uppercase mono text |
| `tally_coding_app/lib/widgets/brutal/tally_avatar.dart` | Solid green block + "T" + cursor blink badge |
| `tally_coding_app/lib/widgets/brutal/agent_avatar.dart` | ANSI-tinted block + monogram + internal cursor (active state) |
| `tally_coding_app/lib/widgets/brutal/brutal.dart` | Barrel export |
| `tally_coding_app/lib/screens/theme_picker_screen.dart` | Full-screen theme picker (sidebar + preview) |
| `tally_coding_app/test/theme/tc_tokens_test.dart` | TCTokens shape, lerp, copyWith |
| `tally_coding_app/test/theme/theme_builder_test.dart` | themeFromTokens produces valid ThemeData |
| `tally_coding_app/test/theme/theme_catalog_test.dart` | All 28 themes, completeness, contrast |
| `tally_coding_app/test/theme/theme_controller_test.dart` | Controller state, persistence, fallback |
| `tally_coding_app/test/widgets/brutal/cursor_blink_test.dart` | Animation alternates |
| `tally_coding_app/test/widgets/brutal/brutal_card_test.dart` | Renders + hover state |
| `tally_coding_app/test/widgets/brutal/brutal_bubble_test.dart` | Content + max-width |
| `tally_coding_app/test/widgets/brutal/brutal_progress_bar_test.dart` | Fill percentage |
| `tally_coding_app/test/widgets/brutal/brutal_button_test.dart` | Primary + outline + tap |
| `tally_coding_app/test/widgets/brutal/brutal_pill_test.dart` | Border + uppercase |
| `tally_coding_app/test/widgets/brutal/tally_avatar_test.dart` | Block + T + blink |
| `tally_coding_app/test/widgets/brutal/agent_avatar_test.dart` | Per-role colors + monogram |
| `tally_coding_app/test/widgets/brutal/golden_test_helper.dart` | Helper to render widgets across themes for golden tests |
| `tally_coding_app/test/widgets/brutal/golden_test.dart` | Golden matrix: each primitive × {Tokyo Night, Solarized Light} |
| `tally_coding_app/test/screens/theme_picker_screen_test.dart` | Picker filter, tap-to-apply, preview reflects selection |
| `tally_coding_app/.mcp.json` | Dart/Flutter MCP server config |
| `tally_coding_app/CLAUDE.md` | Agent context for the Flutter app dir |

### Modify

| Path | Why |
|---|---|
| `tally_coding_app/pubspec.yaml` | Add `google_fonts` + `provider` deps |
| `tally_coding_app/lib/main.dart` | Wire ChangeNotifierProvider<ThemeController>; rebuild ThemeData from active theme on change |
| `tally_coding_app/lib/screens/workspace_settings.dart` | Add "Appearance" tab; navigation to ThemePickerScreen |

---

## Tasks

### Task 1: Add `google_fonts` + `provider` dependencies

**Files:**
- Modify: `tally_coding_app/pubspec.yaml`

- [ ] **Step 1: Read current dependencies block**

Run: `grep -A 30 '^dependencies:' tally_coding_app/pubspec.yaml`

Expected: existing list including `shared_preferences: ^2.5.5`, `clerk_flutter: ^0.0.15-beta`, etc.

- [ ] **Step 2: Add deps**

Add under `dependencies:` (alphabetically appropriate):

```yaml
  google_fonts: ^6.2.1
  provider: ^6.1.2
```

- [ ] **Step 3: Run pub get**

Run: `cd tally_coding_app && flutter pub get`
Expected: "Got dependencies!" with no version conflicts.

- [ ] **Step 4: Commit**

```bash
git add tally_coding_app/pubspec.yaml tally_coding_app/pubspec.lock
git commit -m "[app] add google_fonts + provider for theme system"
```

---

### Task 2: TCTokens ThemeExtension — shape + copyWith + lerp

**Files:**
- Create: `tally_coding_app/lib/theme/tc_tokens.dart`
- Create: `tally_coding_app/test/theme/tc_tokens_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `tally_coding_app/test/theme/tc_tokens_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

void main() {
  group('TCTokens', () {
    const sample = TCTokens(
      bg: Color(0xFF1A1B26),
      elev: Color(0xFF24283B),
      sheet: Color(0xFF1F2030),
      border: Color(0xFF2F3349),
      borderStr: Color(0xFF3B3F5C),
      fg: Color(0xFFC0CAF5),
      fgDim: Color(0xFFA9B1D6),
      fgXdim: Color(0xFF7A82AF),
      fgDimmer: Color(0xFF565F89),
      green: Color(0xFF9ECE6A),
      red: Color(0xFFF7768E),
      cyan: Color(0xFF7DCFFF),
      magenta: Color(0xFFBB9AF7),
      yellow: Color(0xFFE0AF68),
      orange: Color(0xFFFF9E64),
      card: Color(0x0AC0CAF5),
      cardHov: Color(0x12C0CAF5),
      bubble: Color(0x0FC0CAF5),
    );

    test('all required tokens present', () {
      expect(sample.bg, const Color(0xFF1A1B26));
      expect(sample.fg, const Color(0xFFC0CAF5));
      expect(sample.green, const Color(0xFF9ECE6A));
      expect(sample.red, const Color(0xFFF7768E));
    });

    test('copyWith replaces only specified fields', () {
      final modified = sample.copyWith(bg: const Color(0xFFFFFFFF));
      expect(modified.bg, const Color(0xFFFFFFFF));
      expect(modified.fg, sample.fg);
      expect(modified.green, sample.green);
    });

    test('lerp interpolates colors between two themes', () {
      final other = sample.copyWith(bg: const Color(0xFFFFFFFF));
      final mid = sample.lerp(other, 0.5)!;
      expect(mid.bg.r, closeTo(0.55, 0.05));  // (0x1A + 0xFF) / 2 / 255
    });

    test('lerp returns self when other is null', () {
      final result = sample.lerp(null, 0.5);
      expect(result, sample);
    });

    test('lerp returns self at t=0', () {
      final other = sample.copyWith(bg: const Color(0xFFFFFFFF));
      final result = sample.lerp(other, 0.0)!;
      expect(result.bg, sample.bg);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/theme/tc_tokens_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'tally_coding_app/theme/tc_tokens.dart'`

- [ ] **Step 3: Implement TCTokens**

Create `tally_coding_app/lib/theme/tc_tokens.dart`:

```dart
import 'package:flutter/material.dart';

@immutable
class TCTokens extends ThemeExtension<TCTokens> {
  // Surfaces
  final Color bg;
  final Color elev;
  final Color sheet;
  final Color border;
  final Color borderStr;

  // Text hierarchy
  final Color fg;
  final Color fgDim;
  final Color fgXdim;
  final Color fgDimmer;

  // Signal colors (ANSI-mapped)
  final Color green;    // Tally · healthy · success · primary CTA
  final Color red;      // escalation · alert · attention
  final Color cyan;     // Coder agent
  final Color magenta;  // Architect agent
  final Color yellow;   // Reader agent
  final Color orange;   // Tester agent

  // Overlays / hover states
  final Color card;
  final Color cardHov;
  final Color bubble;

  const TCTokens({
    required this.bg,
    required this.elev,
    required this.sheet,
    required this.border,
    required this.borderStr,
    required this.fg,
    required this.fgDim,
    required this.fgXdim,
    required this.fgDimmer,
    required this.green,
    required this.red,
    required this.cyan,
    required this.magenta,
    required this.yellow,
    required this.orange,
    required this.card,
    required this.cardHov,
    required this.bubble,
  });

  @override
  TCTokens copyWith({
    Color? bg,
    Color? elev,
    Color? sheet,
    Color? border,
    Color? borderStr,
    Color? fg,
    Color? fgDim,
    Color? fgXdim,
    Color? fgDimmer,
    Color? green,
    Color? red,
    Color? cyan,
    Color? magenta,
    Color? yellow,
    Color? orange,
    Color? card,
    Color? cardHov,
    Color? bubble,
  }) {
    return TCTokens(
      bg: bg ?? this.bg,
      elev: elev ?? this.elev,
      sheet: sheet ?? this.sheet,
      border: border ?? this.border,
      borderStr: borderStr ?? this.borderStr,
      fg: fg ?? this.fg,
      fgDim: fgDim ?? this.fgDim,
      fgXdim: fgXdim ?? this.fgXdim,
      fgDimmer: fgDimmer ?? this.fgDimmer,
      green: green ?? this.green,
      red: red ?? this.red,
      cyan: cyan ?? this.cyan,
      magenta: magenta ?? this.magenta,
      yellow: yellow ?? this.yellow,
      orange: orange ?? this.orange,
      card: card ?? this.card,
      cardHov: cardHov ?? this.cardHov,
      bubble: bubble ?? this.bubble,
    );
  }

  @override
  TCTokens lerp(ThemeExtension<TCTokens>? other, double t) {
    if (other is! TCTokens) return this;
    return TCTokens(
      bg: Color.lerp(bg, other.bg, t)!,
      elev: Color.lerp(elev, other.elev, t)!,
      sheet: Color.lerp(sheet, other.sheet, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStr: Color.lerp(borderStr, other.borderStr, t)!,
      fg: Color.lerp(fg, other.fg, t)!,
      fgDim: Color.lerp(fgDim, other.fgDim, t)!,
      fgXdim: Color.lerp(fgXdim, other.fgXdim, t)!,
      fgDimmer: Color.lerp(fgDimmer, other.fgDimmer, t)!,
      green: Color.lerp(green, other.green, t)!,
      red: Color.lerp(red, other.red, t)!,
      cyan: Color.lerp(cyan, other.cyan, t)!,
      magenta: Color.lerp(magenta, other.magenta, t)!,
      yellow: Color.lerp(yellow, other.yellow, t)!,
      orange: Color.lerp(orange, other.orange, t)!,
      card: Color.lerp(card, other.card, t)!,
      cardHov: Color.lerp(cardHov, other.cardHov, t)!,
      bubble: Color.lerp(bubble, other.bubble, t)!,
    );
  }
}

/// Convenience accessor: `context.tc` → TCTokens instance for the active theme.
extension TCThemeAccess on BuildContext {
  TCTokens get tc => Theme.of(this).extension<TCTokens>()!;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/theme/tc_tokens_test.dart`
Expected: PASS — 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/theme/tc_tokens.dart tally_coding_app/test/theme/tc_tokens_test.dart
git commit -m "[theme] TCTokens ThemeExtension (Brutal Terminal token system)"
```

---

### Task 3: themeFromTokens builder

**Files:**
- Create: `tally_coding_app/lib/theme/theme_builder.dart`
- Create: `tally_coding_app/test/theme/theme_builder_test.dart`

- [ ] **Step 1: Write the failing test**

Create `tally_coding_app/test/theme/theme_builder_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/theme/theme_builder.dart';

void main() {
  const sample = TCTokens(
    bg: Color(0xFF1A1B26),
    elev: Color(0xFF24283B),
    sheet: Color(0xFF1F2030),
    border: Color(0xFF2F3349),
    borderStr: Color(0xFF3B3F5C),
    fg: Color(0xFFC0CAF5),
    fgDim: Color(0xFFA9B1D6),
    fgXdim: Color(0xFF7A82AF),
    fgDimmer: Color(0xFF565F89),
    green: Color(0xFF9ECE6A),
    red: Color(0xFFF7768E),
    cyan: Color(0xFF7DCFFF),
    magenta: Color(0xFFBB9AF7),
    yellow: Color(0xFFE0AF68),
    orange: Color(0xFFFF9E64),
    card: Color(0x0AC0CAF5),
    cardHov: Color(0x12C0CAF5),
    bubble: Color(0x0FC0CAF5),
  );

  group('themeFromTokens', () {
    test('produces ThemeData with TCTokens extension attached', () {
      final theme = themeFromTokens(sample);
      expect(theme.extension<TCTokens>(), sample);
    });

    test('scaffoldBackgroundColor matches tokens.bg', () {
      final theme = themeFromTokens(sample);
      expect(theme.scaffoldBackgroundColor, sample.bg);
    });

    test('uses dark brightness for dark themes', () {
      final theme = themeFromTokens(sample);
      // sample.bg luminance < 0.5 → dark
      expect(theme.brightness, Brightness.dark);
    });

    test('uses light brightness for light themes', () {
      final lightTokens = sample.copyWith(
        bg: const Color(0xFFFDF6E3),
        fg: const Color(0xFF073642),
      );
      final theme = themeFromTokens(lightTokens);
      expect(theme.brightness, Brightness.light);
    });

    test('uses JetBrains Mono for text theme', () {
      final theme = themeFromTokens(sample);
      // GoogleFonts.jetBrainsMono sets fontFamily to 'JetBrainsMono'
      expect(theme.textTheme.bodyMedium?.fontFamily, contains('JetBrainsMono'));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/theme/theme_builder_test.dart`
Expected: FAIL — `'package:tally_coding_app/theme/theme_builder.dart'` not found.

- [ ] **Step 3: Implement themeFromTokens**

Create `tally_coding_app/lib/theme/theme_builder.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

/// Build a Brutal Terminal ThemeData from the given token set.
///
/// Determines brightness automatically from `tokens.bg` luminance:
/// luminance < 0.5 → dark; >= 0.5 → light.
ThemeData themeFromTokens(TCTokens tokens) {
  final isDark =
      ThemeData.estimateBrightnessForColor(tokens.bg) == Brightness.dark;
  final brightness = isDark ? Brightness.dark : Brightness.light;

  final textTheme = GoogleFonts.jetBrainsMonoTextTheme(
    isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
  ).apply(
    bodyColor: tokens.fg,
    displayColor: tokens.fg,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: tokens.bg,
    canvasColor: tokens.bg,
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: tokens.green,
      onPrimary: tokens.bg,
      secondary: tokens.cyan,
      onSecondary: tokens.bg,
      error: tokens.red,
      onError: tokens.bg,
      surface: tokens.elev,
      onSurface: tokens.fg,
    ),
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    dividerColor: tokens.border,
    dividerTheme: DividerThemeData(color: tokens.border, thickness: 1),
    iconTheme: IconThemeData(color: tokens.fgDim, size: 18),
    extensions: [tokens],
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/theme/theme_builder_test.dart`
Expected: PASS — 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/theme/theme_builder.dart tally_coding_app/test/theme/theme_builder_test.dart
git commit -m "[theme] themeFromTokens builder (ThemeData from TCTokens)"
```

---

### Task 4: Theme catalog — Tokyo Night + structure

**Files:**
- Create: `tally_coding_app/lib/theme/theme_catalog.dart`
- Create: `tally_coding_app/test/theme/theme_catalog_test.dart`

- [ ] **Step 1: Write the failing test**

Create `tally_coding_app/test/theme/theme_catalog_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';

void main() {
  group('themeCatalog', () {
    test('contains tokyo-night as the default', () {
      expect(themeCatalog.containsKey('tokyo-night'), isTrue);
      expect(defaultThemeSlug, 'tokyo-night');
    });

    test('tokyo-night has expected token values', () {
      final t = themeCatalog['tokyo-night']!;
      expect(t.tokens.bg.r, closeTo(0.10, 0.02));  // #1a1b26
      expect(t.tokens.fg.r, closeTo(0.75, 0.02));  // #c0caf5
      expect(t.tokens.green.r, closeTo(0.62, 0.02));  // #9ece6a
    });

    test('every theme entry has a name and desc', () {
      for (final entry in themeCatalog.values) {
        expect(entry.name, isNotEmpty);
        expect(entry.desc, isNotEmpty);
      }
    });

    test('theme groups are defined', () {
      expect(themeGroups.length, 4);
      expect(themeGroups, contains('Modern Favorites'));
      expect(themeGroups, contains('Classics'));
      expect(themeGroups, contains('Statement'));
      expect(themeGroups, contains('Light'));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/theme/theme_catalog_test.dart`
Expected: FAIL — `theme_catalog.dart` not found.

- [ ] **Step 3: Implement catalog skeleton with Tokyo Night**

Create `tally_coding_app/lib/theme/theme_catalog.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

@immutable
class ThemeEntry {
  final String name;
  final String desc;
  final String group;
  final TCTokens tokens;
  const ThemeEntry({
    required this.name,
    required this.desc,
    required this.group,
    required this.tokens,
  });
}

const String defaultThemeSlug = 'tokyo-night';

const List<String> themeGroups = [
  'Modern Favorites',
  'Classics',
  'Statement',
  'Light',
];

/// All 28 curated terminal themes that ship with Tally Coding.
/// Sourced from iTerm2-Color-Schemes / standard ANSI palette repos.
const Map<String, ThemeEntry> themeCatalog = {
  'tokyo-night': ThemeEntry(
    name: 'Tokyo Night',
    desc: 'Deep blue-purple · sage · coral',
    group: 'Modern Favorites',
    tokens: TCTokens(
      bg: Color(0xFF1A1B26),
      elev: Color(0xFF24283B),
      sheet: Color(0xFF1F2030),
      border: Color(0xFF2F3349),
      borderStr: Color(0xFF3B3F5C),
      fg: Color(0xFFC0CAF5),
      fgDim: Color(0xFFA9B1D6),
      fgXdim: Color(0xFF7A82AF),
      fgDimmer: Color(0xFF565F89),
      green: Color(0xFF9ECE6A),
      red: Color(0xFFF7768E),
      cyan: Color(0xFF7DCFFF),
      magenta: Color(0xFFBB9AF7),
      yellow: Color(0xFFE0AF68),
      orange: Color(0xFFFF9E64),
      card: Color(0x0AC0CAF5),
      cardHov: Color(0x12C0CAF5),
      bubble: Color(0x0FC0CAF5),
    ),
  ),
};
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/theme/theme_catalog_test.dart`
Expected: PASS — 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/theme/theme_catalog.dart tally_coding_app/test/theme/theme_catalog_test.dart
git commit -m "[theme] theme catalog skeleton + Tokyo Night default"
```

---

### Task 5: Populate the remaining 27 themes

**Files:**
- Modify: `tally_coding_app/lib/theme/theme_catalog.dart`
- Modify: `tally_coding_app/test/theme/theme_catalog_test.dart`

The data for all 28 themes is in `docs/design/claude-design/tc-shared.jsx` (Tokyo Night only) plus the reference picker (transient at `/tmp/tally-vid-exploration/index.html`, not committed). The full token set below comes from iTerm2-Color-Schemes / official theme repos.

For `card`, `cardHov`, `bubble` overlay tokens: derive from each theme's `fg` color at alpha `0x0A`, `0x12`, `0x0F` respectively (matches Tokyo Night's pattern).

- [ ] **Step 1: Write the failing tests**

Update `tally_coding_app/test/theme/theme_catalog_test.dart` to add:

```dart
    test('exactly 28 themes ship at launch', () {
      expect(themeCatalog.length, 28);
    });

    test('all themes have valid groups', () {
      for (final entry in themeCatalog.values) {
        expect(themeGroups, contains(entry.group));
      }
    });

    test('group distribution: 9 modern, 11 classics, 4 statement, 4 light', () {
      final counts = <String, int>{};
      for (final entry in themeCatalog.values) {
        counts[entry.group] = (counts[entry.group] ?? 0) + 1;
      }
      expect(counts['Modern Favorites'], 9);
      expect(counts['Classics'], 11);
      expect(counts['Statement'], 4);
      expect(counts['Light'], 4);
    });

    test('every theme has fg/bg contrast suitable for body text (WCAG AA: 4.5:1)', () {
      double luminance(Color c) => c.computeLuminance();
      double contrast(Color a, Color b) {
        final la = luminance(a);
        final lb = luminance(b);
        final l1 = la > lb ? la : lb;
        final l2 = la > lb ? lb : la;
        return (l1 + 0.05) / (l2 + 0.05);
      }

      for (final entry in themeCatalog.entries) {
        final ratio = contrast(entry.value.tokens.fg, entry.value.tokens.bg);
        expect(ratio, greaterThan(4.5),
            reason: '${entry.key} fg/bg contrast=$ratio fails WCAG AA');
      }
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd tally_coding_app && flutter test test/theme/theme_catalog_test.dart`
Expected: FAIL — `expected 28, was 1`.

- [ ] **Step 3: Add the 27 remaining themes**

In `tally_coding_app/lib/theme/theme_catalog.dart`, add these entries to the `themeCatalog` map. Use the same overlay pattern (alpha 0x0A/0x12/0x0F on fg) for `card`/`cardHov`/`bubble`.

```dart
  // ─── Modern Favorites ───
  'tokyo-night-storm': ThemeEntry(
    name: 'Tokyo Night Storm',
    desc: 'Slightly lighter Tokyo Night',
    group: 'Modern Favorites',
    tokens: TCTokens(
      bg: Color(0xFF24283B), elev: Color(0xFF2D3149), sheet: Color(0xFF2A2E45),
      border: Color(0xFF3B3F5C), borderStr: Color(0xFF464B6E),
      fg: Color(0xFFC0CAF5), fgDim: Color(0xFFA9B1D6),
      fgXdim: Color(0xFF7A82AF), fgDimmer: Color(0xFF565F89),
      green: Color(0xFF9ECE6A), red: Color(0xFFF7768E),
      cyan: Color(0xFF7DCFFF), magenta: Color(0xFFBB9AF7),
      yellow: Color(0xFFE0AF68), orange: Color(0xFFFF9E64),
      card: Color(0x0AC0CAF5), cardHov: Color(0x12C0CAF5), bubble: Color(0x0FC0CAF5),
    ),
  ),
  'catppuccin-mocha': ThemeEntry(
    name: 'Catppuccin Mocha',
    desc: 'Soft pastel dark · cozy',
    group: 'Modern Favorites',
    tokens: TCTokens(
      bg: Color(0xFF1E1E2E), elev: Color(0xFF272838), sheet: Color(0xFF222232),
      border: Color(0xFF313244), borderStr: Color(0xFF3D3F5A),
      fg: Color(0xFFCDD6F4), fgDim: Color(0xFFA6ADC8),
      fgXdim: Color(0xFF7F849C), fgDimmer: Color(0xFF6C7086),
      green: Color(0xFFA6E3A1), red: Color(0xFFF38BA8),
      cyan: Color(0xFF94E2D5), magenta: Color(0xFFCBA6F7),
      yellow: Color(0xFFF9E2AF), orange: Color(0xFFFAB387),
      card: Color(0x0ACDD6F4), cardHov: Color(0x12CDD6F4), bubble: Color(0x0FCDD6F4),
    ),
  ),
  'catppuccin-macchiato': ThemeEntry(
    name: 'Catppuccin Macchiato',
    desc: 'Medium-dark Catppuccin',
    group: 'Modern Favorites',
    tokens: TCTokens(
      bg: Color(0xFF24273A), elev: Color(0xFF2E314A), sheet: Color(0xFF2A2C42),
      border: Color(0xFF363A4F), borderStr: Color(0xFF494D67),
      fg: Color(0xFFCAD3F5), fgDim: Color(0xFFA5ADCB),
      fgXdim: Color(0xFF8087A2), fgDimmer: Color(0xFF6E738D),
      green: Color(0xFFA6DA95), red: Color(0xFFED8796),
      cyan: Color(0xFF8BD5CA), magenta: Color(0xFFC6A0F6),
      yellow: Color(0xFFEED49F), orange: Color(0xFFF5A97F),
      card: Color(0x0ACAD3F5), cardHov: Color(0x12CAD3F5), bubble: Color(0x0FCAD3F5),
    ),
  ),
  'catppuccin-frappe': ThemeEntry(
    name: 'Catppuccin Frappé',
    desc: 'Warmer Catppuccin',
    group: 'Modern Favorites',
    tokens: TCTokens(
      bg: Color(0xFF303446), elev: Color(0xFF3A3E54), sheet: Color(0xFF353951),
      border: Color(0xFF414559), borderStr: Color(0xFF51596F),
      fg: Color(0xFFC6D0F5), fgDim: Color(0xFFA5ADCE),
      fgXdim: Color(0xFF838BA7), fgDimmer: Color(0xFF737994),
      green: Color(0xFFA6D189), red: Color(0xFFE78284),
      cyan: Color(0xFF81C8BE), magenta: Color(0xFFCA9EE6),
      yellow: Color(0xFFE5C890), orange: Color(0xFFEF9F76),
      card: Color(0x0AC6D0F5), cardHov: Color(0x12C6D0F5), bubble: Color(0x0FC6D0F5),
    ),
  ),
  'rose-pine': ThemeEntry(
    name: 'Rosé Pine',
    desc: 'Soho-vibes · rose + pine accents',
    group: 'Modern Favorites',
    tokens: TCTokens(
      bg: Color(0xFF191724), elev: Color(0xFF1F1D2E), sheet: Color(0xFF1B1928),
      border: Color(0xFF26233A), borderStr: Color(0xFF3B384D),
      fg: Color(0xFFE0DEF4), fgDim: Color(0xFF908CAA),
      fgXdim: Color(0xFF6E6A86), fgDimmer: Color(0xFF555169),
      green: Color(0xFF9CCFD8), red: Color(0xFFEB6F92),
      cyan: Color(0xFF31748F), magenta: Color(0xFFC4A7E7),
      yellow: Color(0xFFF6C177), orange: Color(0xFFEBBCBA),
      card: Color(0x0AE0DEF4), cardHov: Color(0x12E0DEF4), bubble: Color(0x0FE0DEF4),
    ),
  ),
  'rose-pine-moon': ThemeEntry(
    name: 'Rosé Pine Moon',
    desc: 'Lighter Rosé Pine · dusky',
    group: 'Modern Favorites',
    tokens: TCTokens(
      bg: Color(0xFF232136), elev: Color(0xFF2A283E), sheet: Color(0xFF26243A),
      border: Color(0xFF393552), borderStr: Color(0xFF4A4666),
      fg: Color(0xFFE0DEF4), fgDim: Color(0xFF908CAA),
      fgXdim: Color(0xFF6E6A86), fgDimmer: Color(0xFF555169),
      green: Color(0xFF9CCFD8), red: Color(0xFFEB6F92),
      cyan: Color(0xFF3E8FB0), magenta: Color(0xFFC4A7E7),
      yellow: Color(0xFFF6C177), orange: Color(0xFFEA9A97),
      card: Color(0x0AE0DEF4), cardHov: Color(0x12E0DEF4), bubble: Color(0x0FE0DEF4),
    ),
  ),
  'kanagawa-wave': ThemeEntry(
    name: 'Kanagawa Wave',
    desc: 'Wabi-sabi · muted earth · Hokusai',
    group: 'Modern Favorites',
    tokens: TCTokens(
      bg: Color(0xFF1F1F28), elev: Color(0xFF2A2A37), sheet: Color(0xFF252531),
      border: Color(0xFF363646), borderStr: Color(0xFF44445A),
      fg: Color(0xFFDCD7BA), fgDim: Color(0xFFC8C093),
      fgXdim: Color(0xFF9C9075), fgDimmer: Color(0xFF727169),
      green: Color(0xFF76946A), red: Color(0xFFC34043),
      cyan: Color(0xFF7AA89F), magenta: Color(0xFF957FB8),
      yellow: Color(0xFFDCA561), orange: Color(0xFFFFA066),
      card: Color(0x0ADCD7BA), cardHov: Color(0x12DCD7BA), bubble: Color(0x0FDCD7BA),
    ),
  ),
  'everforest-dark': ThemeEntry(
    name: 'Everforest Dark',
    desc: 'Soft green + beige forest',
    group: 'Modern Favorites',
    tokens: TCTokens(
      bg: Color(0xFF2D353B), elev: Color(0xFF374145), sheet: Color(0xFF323A40),
      border: Color(0xFF3D484D), borderStr: Color(0xFF4F5B63),
      fg: Color(0xFFD3C6AA), fgDim: Color(0xFF9DA9A0),
      fgXdim: Color(0xFF859289), fgDimmer: Color(0xFF7A8478),
      green: Color(0xFFA7C080), red: Color(0xFFE67E80),
      cyan: Color(0xFF7FBBB3), magenta: Color(0xFFD699B6),
      yellow: Color(0xFFDBBC7F), orange: Color(0xFFE69875),
      card: Color(0x0AD3C6AA), cardHov: Color(0x12D3C6AA), bubble: Color(0x0FD3C6AA),
    ),
  ),

  // ─── Classics ───
  'one-dark': ThemeEntry(
    name: 'One Dark', desc: 'Atom default · muted, balanced',
    group: 'Classics',
    tokens: TCTokens(
      bg: Color(0xFF282C34), elev: Color(0xFF353A45), sheet: Color(0xFF30343D),
      border: Color(0xFF3E4451), borderStr: Color(0xFF4E5462),
      fg: Color(0xFFABB2BF), fgDim: Color(0xFF828997),
      fgXdim: Color(0xFF6B7280), fgDimmer: Color(0xFF5C6370),
      green: Color(0xFF98C379), red: Color(0xFFE06C75),
      cyan: Color(0xFF56B6C2), magenta: Color(0xFFC678DD),
      yellow: Color(0xFFE5C07B), orange: Color(0xFFD19A66),
      card: Color(0x0AABB2BF), cardHov: Color(0x12ABB2BF), bubble: Color(0x0FABB2BF),
    ),
  ),
  'dracula': ThemeEntry(
    name: 'Dracula', desc: 'Friendly purple-tinted dark',
    group: 'Classics',
    tokens: TCTokens(
      bg: Color(0xFF282A36), elev: Color(0xFF373948), sheet: Color(0xFF313340),
      border: Color(0xFF44475A), borderStr: Color(0xFF565969),
      fg: Color(0xFFF8F8F2), fgDim: Color(0xFFBBBBBB),
      fgXdim: Color(0xFF8B91B8), fgDimmer: Color(0xFF6272A4),
      green: Color(0xFF50FA7B), red: Color(0xFFFF5555),
      cyan: Color(0xFF8BE9FD), magenta: Color(0xFFFF79C6),
      yellow: Color(0xFFF1FA8C), orange: Color(0xFFFFB86C),
      card: Color(0x0AF8F8F2), cardHov: Color(0x12F8F8F2), bubble: Color(0x0FF8F8F2),
    ),
  ),
  'monokai-classic': ThemeEntry(
    name: 'Monokai Classic', desc: 'Sublime default · black-green-pink',
    group: 'Classics',
    tokens: TCTokens(
      bg: Color(0xFF272822), elev: Color(0xFF35362F), sheet: Color(0xFF2F3028),
      border: Color(0xFF3E3D32), borderStr: Color(0xFF504F40),
      fg: Color(0xFFF8F8F2), fgDim: Color(0xFFA59F85),
      fgXdim: Color(0xFF8A8472), fgDimmer: Color(0xFF75715E),
      green: Color(0xFFA6E22E), red: Color(0xFFF92672),
      cyan: Color(0xFF66D9EF), magenta: Color(0xFFAE81FF),
      yellow: Color(0xFFE6DB74), orange: Color(0xFFFD971F),
      card: Color(0x0AF8F8F2), cardHov: Color(0x12F8F8F2), bubble: Color(0x0FF8F8F2),
    ),
  ),
  'monokai-pro': ThemeEntry(
    name: 'Monokai Pro', desc: 'Refined Monokai · warmer',
    group: 'Classics',
    tokens: TCTokens(
      bg: Color(0xFF2D2A2E), elev: Color(0xFF3A363B), sheet: Color(0xFF353035),
      border: Color(0xFF403E41), borderStr: Color(0xFF525052),
      fg: Color(0xFFFCFCFA), fgDim: Color(0xFFC1C0C0),
      fgXdim: Color(0xFF8F8E8F), fgDimmer: Color(0xFF727072),
      green: Color(0xFFA9DC76), red: Color(0xFFFF6188),
      cyan: Color(0xFF78DCE8), magenta: Color(0xFFAB9DF2),
      yellow: Color(0xFFFFD866), orange: Color(0xFFFC9867),
      card: Color(0x0AFCFCFA), cardHov: Color(0x12FCFCFA), bubble: Color(0x0FFCFCFA),
    ),
  ),
  'nord': ThemeEntry(
    name: 'Nord', desc: 'Arctic blue · cold, calm, restrained',
    group: 'Classics',
    tokens: TCTokens(
      bg: Color(0xFF2E3440), elev: Color(0xFF3B4252), sheet: Color(0xFF353C4A),
      border: Color(0xFF434C5E), borderStr: Color(0xFF4C566A),
      fg: Color(0xFFECEFF4), fgDim: Color(0xFFD8DEE9),
      fgXdim: Color(0xFF7B8298), fgDimmer: Color(0xFF616E88),
      green: Color(0xFFA3BE8C), red: Color(0xFFBF616A),
      cyan: Color(0xFF88C0D0), magenta: Color(0xFFB48EAD),
      yellow: Color(0xFFEBCB8B), orange: Color(0xFFD08770),
      card: Color(0x0AECEFF4), cardHov: Color(0x12ECEFF4), bubble: Color(0x0FECEFF4),
    ),
  ),
  'gruvbox-dark': ThemeEntry(
    name: 'Gruvbox Dark', desc: 'Retro warm dark · beige + olive',
    group: 'Classics',
    tokens: TCTokens(
      bg: Color(0xFF282828), elev: Color(0xFF3C3836), sheet: Color(0xFF32302F),
      border: Color(0xFF504945), borderStr: Color(0xFF665C54),
      fg: Color(0xFFEBDBB2), fgDim: Color(0xFFBDAE93),
      fgXdim: Color(0xFFA89984), fgDimmer: Color(0xFF7C6F64),
      green: Color(0xFFB8BB26), red: Color(0xFFFB4934),
      cyan: Color(0xFF8EC07C), magenta: Color(0xFFD3869B),
      yellow: Color(0xFFFABD2F), orange: Color(0xFFFE8019),
      card: Color(0x0AEBDBB2), cardHov: Color(0x12EBDBB2), bubble: Color(0x0FEBDBB2),
    ),
  ),
  'gruvbox-material': ThemeEntry(
    name: 'Gruvbox Material', desc: 'Softer Gruvbox · less saturated',
    group: 'Classics',
    tokens: TCTokens(
      bg: Color(0xFF1D2021), elev: Color(0xFF32302F), sheet: Color(0xFF272727),
      border: Color(0xFF3C3836), borderStr: Color(0xFF504945),
      fg: Color(0xFFD4BE98), fgDim: Color(0xFFA89984),
      fgXdim: Color(0xFF82776C), fgDimmer: Color(0xFF665C54),
      green: Color(0xFFA9B665), red: Color(0xFFEA6962),
      cyan: Color(0xFF89B482), magenta: Color(0xFFD3869B),
      yellow: Color(0xFFD8A657), orange: Color(0xFFE78A4E),
      card: Color(0x0AD4BE98), cardHov: Color(0x12D4BE98), bubble: Color(0x0FD4BE98),
    ),
  ),
  'solarized-dark': ThemeEntry(
    name: 'Solarized Dark', desc: 'Teal-dark · olive · brick red',
    group: 'Classics',
    tokens: TCTokens(
      bg: Color(0xFF002B36), elev: Color(0xFF073642), sheet: Color(0xFF04303D),
      border: Color(0xFF0F4151), borderStr: Color(0xFF1A5365),
      fg: Color(0xFFFDF6E3), fgDim: Color(0xFF93A1A1),
      fgXdim: Color(0xFF6E7B7B), fgDimmer: Color(0xFF586E75),
      green: Color(0xFF859900), red: Color(0xFFDC322F),
      cyan: Color(0xFF2AA198), magenta: Color(0xFF6C71C4),
      yellow: Color(0xFFB58900), orange: Color(0xFFCB4B16),
      card: Color(0x0AFDF6E3), cardHov: Color(0x12FDF6E3), bubble: Color(0x0FFDF6E3),
    ),
  ),
  'ayu-dark': ThemeEntry(
    name: 'Ayu Dark', desc: 'Crisp dark · ochre + teal',
    group: 'Classics',
    tokens: TCTokens(
      bg: Color(0xFF0B0E14), elev: Color(0xFF1B1F2B), sheet: Color(0xFF12161E),
      border: Color(0xFF253142), borderStr: Color(0xFF38465C),
      fg: Color(0xFFB3B1AD), fgDim: Color(0xFF787B80),
      fgXdim: Color(0xFF5C636E), fgDimmer: Color(0xFF475266),
      green: Color(0xFFAAD94C), red: Color(0xFFF07178),
      cyan: Color(0xFF39BAE6), magenta: Color(0xFFD2A6FF),
      yellow: Color(0xFFFFB454), orange: Color(0xFFFF8F40),
      card: Color(0x0AB3B1AD), cardHov: Color(0x12B3B1AD), bubble: Color(0x0FB3B1AD),
    ),
  ),
  'ayu-mirage': ThemeEntry(
    name: 'Ayu Mirage', desc: 'Soft dark · pastel accents',
    group: 'Classics',
    tokens: TCTokens(
      bg: Color(0xFF1F2430), elev: Color(0xFF272D38), sheet: Color(0xFF232834),
      border: Color(0xFF323848), borderStr: Color(0xFF464D5E),
      fg: Color(0xFFCBCCC6), fgDim: Color(0xFF707A8C),
      fgXdim: Color(0xFF666D7E), fgDimmer: Color(0xFF5C6773),
      green: Color(0xFFD5FF80), red: Color(0xFFF28779),
      cyan: Color(0xFF73D0FF), magenta: Color(0xFFDFBFFF),
      yellow: Color(0xFFFFD580), orange: Color(0xFFFFAE57),
      card: Color(0x0ACBCCC6), cardHov: Color(0x12CBCCC6), bubble: Color(0x0FCBCCC6),
    ),
  ),
  'night-owl': ThemeEntry(
    name: 'Night Owl', desc: 'Sarah Drasner · for night coding',
    group: 'Classics',
    tokens: TCTokens(
      bg: Color(0xFF011627), elev: Color(0xFF0E2942), sheet: Color(0xFF062136),
      border: Color(0xFF1D3B53), borderStr: Color(0xFF2C4F6E),
      fg: Color(0xFFD6DEEB), fgDim: Color(0xFF7E97AC),
      fgXdim: Color(0xFF6B8AA0), fgDimmer: Color(0xFF5F7E97),
      green: Color(0xFF22DA6E), red: Color(0xFFEF5350),
      cyan: Color(0xFF21C7A8), magenta: Color(0xFFC792EA),
      yellow: Color(0xFFFFEB95), orange: Color(0xFFF78C6C),
      card: Color(0x0AD6DEEB), cardHov: Color(0x12D6DEEB), bubble: Color(0x0FD6DEEB),
    ),
  ),

  // ─── Statement ───
  'synthwave-84': ThemeEntry(
    name: "Synthwave '84", desc: 'Neon noir · electric pink + cyan',
    group: 'Statement',
    tokens: TCTokens(
      bg: Color(0xFF241B2F), elev: Color(0xFF34294F), sheet: Color(0xFF2C2240),
      border: Color(0xFF3F2E63), borderStr: Color(0xFF534180),
      fg: Color(0xFFF0EFF1), fgDim: Color(0xFFB6B1B1),
      fgXdim: Color(0xFF867D9C), fgDimmer: Color(0xFF6A5980),
      green: Color(0xFF72F1B8), red: Color(0xFFFE4450),
      cyan: Color(0xFF03EDF9), magenta: Color(0xFFFF7EDB),
      yellow: Color(0xFFFEDE5D), orange: Color(0xFFF97E72),
      card: Color(0x0AF0EFF1), cardHov: Color(0x12F0EFF1), bubble: Color(0x0FF0EFF1),
    ),
  ),
  'phosphor-green': ThemeEntry(
    name: 'Phosphor Green', desc: 'Pure CRT · green on near-black',
    group: 'Statement',
    tokens: TCTokens(
      bg: Color(0xFF000000), elev: Color(0xFF0A1A0A), sheet: Color(0xFF051005),
      border: Color(0xFF1A3A1A), borderStr: Color(0xFF2A5A2A),
      fg: Color(0xFF33FF33), fgDim: Color(0xFF22AA22),
      fgXdim: Color(0xFF1A7A1A), fgDimmer: Color(0xFF155515),
      green: Color(0xFF33FF33), red: Color(0xFFFF3030),
      cyan: Color(0xFF7CFFAF), magenta: Color(0xFFCC9900),
      yellow: Color(0xFFFFFF66), orange: Color(0xFFFF8800),
      card: Color(0x0A33FF33), cardHov: Color(0x1233FF33), bubble: Color(0x0F33FF33),
    ),
  ),
  'phosphor-amber': ThemeEntry(
    name: 'Phosphor Amber', desc: 'CRT amber · vintage terminal',
    group: 'Statement',
    tokens: TCTokens(
      bg: Color(0xFF000000), elev: Color(0xFF2A1808), sheet: Color(0xFF1A1006),
      border: Color(0xFF3A2511), borderStr: Color(0xFF553719),
      fg: Color(0xFFFFB000), fgDim: Color(0xFFCC7700),
      fgXdim: Color(0xFF885000), fgDimmer: Color(0xFF553300),
      green: Color(0xFFFFD700), red: Color(0xFFFF5520),
      cyan: Color(0xFFFFE097), magenta: Color(0xFFCC4400),
      yellow: Color(0xFFFFE000), orange: Color(0xFFFF8800),
      card: Color(0x0AFFB000), cardHov: Color(0x12FFB000), bubble: Color(0x0FFFB000),
    ),
  ),
  'paper-white': ThemeEntry(
    name: 'Paper White', desc: 'Cream bg · ink text · earthy accents',
    group: 'Statement',
    tokens: TCTokens(
      bg: Color(0xFFF4F1E8), elev: Color(0xFFE9E5D5), sheet: Color(0xFFEFEBDC),
      border: Color(0xFFD4CFB8), borderStr: Color(0xFFB8B19A),
      fg: Color(0xFF0D0D0D), fgDim: Color(0xFF3A3A3A),
      fgXdim: Color(0xFF6C6C6C), fgDimmer: Color(0xFF8A8A8A),
      green: Color(0xFF5A7A2E), red: Color(0xFFB91C1C),
      cyan: Color(0xFF1E6091), magenta: Color(0xFF7D2F76),
      yellow: Color(0xFF9A7B14), orange: Color(0xFFB35418),
      card: Color(0x0A0D0D0D), cardHov: Color(0x120D0D0D), bubble: Color(0x0F0D0D0D),
    ),
  ),

  // ─── Light ───
  'solarized-light': ThemeEntry(
    name: 'Solarized Light', desc: 'Bone bg · ink text · olive + red',
    group: 'Light',
    tokens: TCTokens(
      bg: Color(0xFFFDF6E3), elev: Color(0xFFEEE8D5), sheet: Color(0xFFF5F0DC),
      border: Color(0xFFE0DABA), borderStr: Color(0xFFCFCAAA),
      fg: Color(0xFF073642), fgDim: Color(0xFF586E75),
      fgXdim: Color(0xFF7E8B8C), fgDimmer: Color(0xFF93A1A1),
      green: Color(0xFF859900), red: Color(0xFFDC322F),
      cyan: Color(0xFF2AA198), magenta: Color(0xFF6C71C4),
      yellow: Color(0xFFB58900), orange: Color(0xFFCB4B16),
      card: Color(0x0A073642), cardHov: Color(0x12073642), bubble: Color(0x0F073642),
    ),
  ),
  'catppuccin-latte': ThemeEntry(
    name: 'Catppuccin Latte', desc: "Catppuccin's only light variant",
    group: 'Light',
    tokens: TCTokens(
      bg: Color(0xFFEFF1F5), elev: Color(0xFFE6E9EF), sheet: Color(0xFFEBEEF3),
      border: Color(0xFFDCE0E8), borderStr: Color(0xFFCCD0DA),
      fg: Color(0xFF4C4F69), fgDim: Color(0xFF6C6F85),
      fgXdim: Color(0xFF7E81A0), fgDimmer: Color(0xFF8C8FA1),
      green: Color(0xFF40A02B), red: Color(0xFFD20F39),
      cyan: Color(0xFF04A5E5), magenta: Color(0xFF8839EF),
      yellow: Color(0xFFDF8E1D), orange: Color(0xFFFE640B),
      card: Color(0x0A4C4F69), cardHov: Color(0x124C4F69), bubble: Color(0x0F4C4F69),
    ),
  ),
  'rose-pine-dawn': ThemeEntry(
    name: 'Rosé Pine Dawn', desc: 'Light Rosé Pine · cream bg',
    group: 'Light',
    tokens: TCTokens(
      bg: Color(0xFFFAF4ED), elev: Color(0xFFF2E9E1), sheet: Color(0xFFF6EEE4),
      border: Color(0xFFE7DCCB), borderStr: Color(0xFFD2C7B6),
      fg: Color(0xFF575279), fgDim: Color(0xFF797593),
      fgXdim: Color(0xFF8B879C), fgDimmer: Color(0xFF9893A5),
      green: Color(0xFF56949F), red: Color(0xFFB4637A),
      cyan: Color(0xFF286983), magenta: Color(0xFF907AA9),
      yellow: Color(0xFFEA9D34), orange: Color(0xFFD7827E),
      card: Color(0x0A575279), cardHov: Color(0x12575279), bubble: Color(0x0F575279),
    ),
  ),
  'gruvbox-light': ThemeEntry(
    name: 'Gruvbox Light', desc: 'Warm cream bg · dark olive text',
    group: 'Light',
    tokens: TCTokens(
      bg: Color(0xFFFBF1C7), elev: Color(0xFFEBDBB2), sheet: Color(0xFFF2E5BC),
      border: Color(0xFFD5C4A1), borderStr: Color(0xFFBDAE93),
      fg: Color(0xFF3C3836), fgDim: Color(0xFF7C6F64),
      fgXdim: Color(0xFF8B7E73), fgDimmer: Color(0xFF928374),
      green: Color(0xFF79740E), red: Color(0xFF9D0006),
      cyan: Color(0xFF427B58), magenta: Color(0xFF8F3F71),
      yellow: Color(0xFFB57614), orange: Color(0xFFAF3A03),
      card: Color(0x0A3C3836), cardHov: Color(0x123C3836), bubble: Color(0x0F3C3836),
    ),
  ),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/theme/theme_catalog_test.dart`
Expected: PASS — all 8 catalog tests pass (28 themes, contrast check, group distribution).

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/theme/theme_catalog.dart tally_coding_app/test/theme/theme_catalog_test.dart
git commit -m "[theme] full 28-theme catalog (modern, classics, statement, light)"
```

---

### Task 6: ThemeController — ChangeNotifier + SharedPreferences persistence

**Files:**
- Create: `tally_coding_app/lib/theme/theme_controller.dart`
- Create: `tally_coding_app/test/theme/theme_controller_test.dart`

- [ ] **Step 1: Write the failing test**

Create `tally_coding_app/test/theme/theme_controller_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';
import 'package:tally_coding_app/theme/theme_controller.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ThemeController', () {
    test('initial state defaults to tokyo-night when no preference', () async {
      final c = ThemeController();
      await c.load();
      expect(c.activeSlug, 'tokyo-night');
      expect(c.activeEntry, themeCatalog['tokyo-night']);
    });

    test('loads persisted preference on init', () async {
      SharedPreferences.setMockInitialValues({'tally_theme_slug': 'dracula'});
      final c = ThemeController();
      await c.load();
      expect(c.activeSlug, 'dracula');
    });

    test('falls back to tokyo-night if persisted slug is invalid', () async {
      SharedPreferences.setMockInitialValues({'tally_theme_slug': 'bogus'});
      final c = ThemeController();
      await c.load();
      expect(c.activeSlug, 'tokyo-night');
    });

    test('setTheme updates active slug and persists', () async {
      final c = ThemeController();
      await c.load();
      await c.setTheme('catppuccin-mocha');
      expect(c.activeSlug, 'catppuccin-mocha');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('tally_theme_slug'), 'catppuccin-mocha');
    });

    test('setTheme to invalid slug is a no-op', () async {
      final c = ThemeController();
      await c.load();
      final initial = c.activeSlug;
      await c.setTheme('bogus');
      expect(c.activeSlug, initial);
    });

    test('setTheme notifies listeners', () async {
      final c = ThemeController();
      await c.load();
      var notified = 0;
      c.addListener(() => notified++);
      await c.setTheme('nord');
      expect(notified, 1);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/theme/theme_controller_test.dart`
Expected: FAIL — `theme_controller.dart` not found.

- [ ] **Step 3: Implement ThemeController**

Create `tally_coding_app/lib/theme/theme_controller.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';

const String _themePrefsKey = 'tally_theme_slug';

class ThemeController extends ChangeNotifier {
  String _activeSlug = defaultThemeSlug;

  String get activeSlug => _activeSlug;
  ThemeEntry get activeEntry => themeCatalog[_activeSlug]!;

  /// Load the persisted theme preference. Falls back to default if missing
  /// or invalid. Call once at app startup before runApp.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final persisted = prefs.getString(_themePrefsKey);
    if (persisted != null && themeCatalog.containsKey(persisted)) {
      _activeSlug = persisted;
    } else {
      _activeSlug = defaultThemeSlug;
    }
    notifyListeners();
  }

  /// Set the active theme by slug. No-op if slug is unknown.
  Future<void> setTheme(String slug) async {
    if (!themeCatalog.containsKey(slug)) return;
    if (slug == _activeSlug) return;
    _activeSlug = slug;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themePrefsKey, slug);
    notifyListeners();
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/theme/theme_controller_test.dart`
Expected: PASS — 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/theme/theme_controller.dart tally_coding_app/test/theme/theme_controller_test.dart
git commit -m "[theme] ThemeController ChangeNotifier + SharedPreferences persistence"
```

---

### Task 7: Theme barrel export

**Files:**
- Create: `tally_coding_app/lib/theme/theme.dart`

- [ ] **Step 1: Create barrel**

```dart
export 'tc_tokens.dart';
export 'theme_builder.dart';
export 'theme_catalog.dart';
export 'theme_controller.dart';
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tally_coding_app && flutter analyze lib/theme/theme.dart`
Expected: "No issues found!"

- [ ] **Step 3: Commit**

```bash
git add tally_coding_app/lib/theme/theme.dart
git commit -m "[theme] barrel export for theme/ module"
```

---

### Task 8: Wire ThemeController into main.dart

**Files:**
- Modify: `tally_coding_app/lib/main.dart`

- [ ] **Step 1: Read current main.dart structure**

Run: `cd tally_coding_app && head -120 lib/main.dart`

Expected: Identify the `runApp(...)` call, the `MaterialApp(theme: ...)` line, and any existing initialization.

- [ ] **Step 2: Modify main.dart to use ThemeController**

Replace the existing `WidgetsFlutterBinding.ensureInitialized()` + `runApp(...)` sequence with:

```dart
// Add at top of file with other imports:
import 'package:provider/provider.dart';
import 'package:tally_coding_app/theme/theme.dart';

// In main():
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final themeController = ThemeController();
  await themeController.load();
  runApp(
    ChangeNotifierProvider.value(
      value: themeController,
      child: const TallyApp(),
    ),
  );
}
```

In the `MaterialApp` widget (find it in `_TallyAppState.build` or equivalent), replace the existing `theme:` argument with:

```dart
// Inside build, before returning MaterialApp:
final controller = context.watch<ThemeController>();
final activeTheme = themeFromTokens(controller.activeEntry.tokens);

return MaterialApp(
  // ... existing args ...
  theme: activeTheme,
  // remove the old Clerk-style hardcoded theme (preserve ClerkThemeExtension if Clerk auth needs it):
  // theme: ThemeData.dark().copyWith(extensions: [ClerkThemeExtension.dark]),
);
```

If Clerk's `ClerkThemeExtension` is required by `clerk_flutter`, merge it into the extensions list:

```dart
theme: activeTheme.copyWith(
  extensions: [
    ...activeTheme.extensions.values,
    ClerkThemeExtension.dark,
  ],
),
```

- [ ] **Step 3: Run app to verify it boots**

Run: `cd tally_coding_app && flutter analyze lib/main.dart`
Expected: "No issues found!"

Run: `cd tally_coding_app && flutter test test/`
Expected: All existing tests still pass (no regressions).

- [ ] **Step 4: Manual smoke test**

Run: `cd tally_coding_app && flutter run -d linux` (or `-d <android-device-id>`)

Expected:
- App boots without crash
- Background is Tokyo Night `#1a1b26` (a noticeable shift from the old `#1E1F22`)
- Text reads JetBrains Mono
- Existing screens still render (may look different — that's expected; the visual rewire happens in B2/B3/B5)

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/main.dart
git commit -m "[app] wire ThemeController + Brutal Terminal ThemeData into main"
```

---

### Task 9: CursorBlink shared animation widget

**Files:**
- Create: `tally_coding_app/lib/widgets/brutal/cursor_blink.dart`
- Create: `tally_coding_app/test/widgets/brutal/cursor_blink_test.dart`

CursorBlink renders a child widget that alternates visible/invisible every 600ms (1.2s full cycle, sharp on/off, no easing). Used by TallyAvatar and AgentAvatar for active-state indicators.

- [ ] **Step 1: Write the failing test**

Create `tally_coding_app/test/widgets/brutal/cursor_blink_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/brutal/cursor_blink.dart';

void main() {
  testWidgets('CursorBlink shows child initially', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CursorBlink(
          child: Container(width: 10, height: 10, color: const Color(0xFF00FF00)),
        ),
      ),
    ));
    expect(find.byType(Container), findsOneWidget);
    final opacity = tester.widget<Opacity>(find.byType(Opacity));
    expect(opacity.opacity, 1.0);
  });

  testWidgets('CursorBlink hides child after 600ms', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CursorBlink(
          child: Container(width: 10, height: 10, color: const Color(0xFF00FF00)),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 601));
    final opacity = tester.widget<Opacity>(find.byType(Opacity));
    expect(opacity.opacity, 0.0);
  });

  testWidgets('CursorBlink alternates at 1.2s cycle', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CursorBlink(
          child: Container(width: 10, height: 10, color: const Color(0xFF00FF00)),
        ),
      ),
    ));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1.0);
    await tester.pump(const Duration(milliseconds: 601));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0.0);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1.0);

    // Dispose to stop the timer (avoids "pending timers" test failure).
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/cursor_blink_test.dart`
Expected: FAIL — `cursor_blink.dart` not found.

- [ ] **Step 3: Implement CursorBlink**

Create `tally_coding_app/lib/widgets/brutal/cursor_blink.dart`:

```dart
import 'dart:async';
import 'package:flutter/material.dart';

/// Terminal cursor blink: sharp on/off, 600ms per phase (1.2s full cycle).
/// No easing. Used for active-state indicators on Tally + agent avatars.
class CursorBlink extends StatefulWidget {
  final Widget child;
  final Duration phase;

  const CursorBlink({
    super.key,
    required this.child,
    this.phase = const Duration(milliseconds: 600),
  });

  @override
  State<CursorBlink> createState() => _CursorBlinkState();
}

class _CursorBlinkState extends State<CursorBlink> {
  bool _visible = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.phase, (_) {
      if (mounted) setState(() => _visible = !_visible);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(opacity: _visible ? 1.0 : 0.0, child: widget.child);
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/cursor_blink_test.dart`
Expected: PASS — 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/brutal/cursor_blink.dart tally_coding_app/test/widgets/brutal/cursor_blink_test.dart
git commit -m "[brutal] CursorBlink shared animation widget (1.2s sharp blink)"
```

---

### Task 10: BrutalCard widget

**Files:**
- Create: `tally_coding_app/lib/widgets/brutal/brutal_card.dart`
- Create: `tally_coding_app/test/widgets/brutal/brutal_card_test.dart`

- [ ] **Step 1: Write the failing test**

Create `tally_coding_app/test/widgets/brutal/brutal_card_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal_card.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: child),
    );
  }

  testWidgets('BrutalCard renders child', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalCard(child: Text('hello')),
    ));
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('BrutalCard has square corners (radius 0)', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalCard(child: SizedBox(width: 100, height: 100)),
    ));
    final container = tester.widget<Container>(
      find.descendant(of: find.byType(BrutalCard), matching: find.byType(Container)).first,
    );
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.zero);
  });

  testWidgets('BrutalCard uses 1px border from tokens.border', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalCard(child: SizedBox(width: 100, height: 100)),
    ));
    final container = tester.widget<Container>(
      find.descendant(of: find.byType(BrutalCard), matching: find.byType(Container)).first,
    );
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.border!.top.width, 1.0);
  });

  testWidgets('BrutalCard has no shadow', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalCard(child: SizedBox(width: 100, height: 100)),
    ));
    final container = tester.widget<Container>(
      find.descendant(of: find.byType(BrutalCard), matching: find.byType(Container)).first,
    );
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.boxShadow, anyOf(isNull, isEmpty));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/brutal_card_test.dart`
Expected: FAIL — `brutal_card.dart` not found.

- [ ] **Step 3: Implement BrutalCard**

Create `tally_coding_app/lib/widgets/brutal/brutal_card.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

/// Square-cornered, 1px-border card. Transparent fill by default.
/// Hover state lifts to tokens.cardHov (desktop only).
class BrutalCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  const BrutalCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(13),
    this.onTap,
  });

  @override
  State<BrutalCard> createState() => _BrutalCardState();
}

class _BrutalCardState extends State<BrutalCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final card = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        padding: widget.padding,
        decoration: BoxDecoration(
          color: _hovered ? tc.cardHov : tc.card,
          border: Border.all(color: _hovered ? tc.borderStr : tc.border, width: 1),
          borderRadius: BorderRadius.zero,
        ),
        child: widget.child,
      ),
    );
    if (widget.onTap == null) return card;
    return GestureDetector(onTap: widget.onTap, child: card);
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/brutal_card_test.dart`
Expected: PASS — 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/brutal/brutal_card.dart tally_coding_app/test/widgets/brutal/brutal_card_test.dart
git commit -m "[brutal] BrutalCard widget (1px border, square, transparent, hover)"
```

---

### Task 11: BrutalBubble widget (Tally narration container)

**Files:**
- Create: `tally_coding_app/lib/widgets/brutal/brutal_bubble.dart`
- Create: `tally_coding_app/test/widgets/brutal/brutal_bubble_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal_bubble.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: child),
    );
  }

  testWidgets('BrutalBubble renders content', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalBubble(child: Text('Diagnosed the bug.')),
    ));
    expect(find.text('Diagnosed the bug.'), findsOneWidget);
  });

  testWidgets('BrutalBubble has square corners', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalBubble(child: Text('x')),
    ));
    final container = tester.widget<Container>(
      find.descendant(of: find.byType(BrutalBubble), matching: find.byType(Container)).first,
    );
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.zero);
  });

  testWidgets('BrutalBubble respects maxWidth', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalBubble(maxWidth: 200, child: Text('x' * 100)),
    ));
    final box = tester.getSize(find.byType(BrutalBubble));
    expect(box.width, lessThanOrEqualTo(200));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/brutal_bubble_test.dart`
Expected: FAIL — `brutal_bubble.dart` not found.

- [ ] **Step 3: Implement BrutalBubble**

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

/// 1px-border square content box used for Tally narration messages.
/// Reads as a quoted block, not a speech tail.
class BrutalBubble extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  const BrutalBubble({
    super.key,
    required this.child,
    this.maxWidth = 280,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: tc.bubble,
          border: Border.all(color: tc.border, width: 1),
          borderRadius: BorderRadius.zero,
        ),
        child: child,
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/brutal_bubble_test.dart`
Expected: PASS — 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/brutal/brutal_bubble.dart tally_coding_app/test/widgets/brutal/brutal_bubble_test.dart
git commit -m "[brutal] BrutalBubble widget (Tally narration container)"
```

---

### Task 12: BrutalProgressBar widget

**Files:**
- Create: `tally_coding_app/lib/widgets/brutal/brutal_progress_bar.dart`
- Create: `tally_coding_app/test/widgets/brutal/brutal_progress_bar_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal_progress_bar.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: SizedBox(width: 200, child: child)),
    );
  }

  testWidgets('BrutalProgressBar renders at correct percentage', (tester) async {
    await tester.pumpWidget(wrap(const BrutalProgressBar(value: 0.6)));
    final fractional = tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox));
    expect(fractional.widthFactor, 0.6);
  });

  testWidgets('BrutalProgressBar clamps value to [0,1]', (tester) async {
    await tester.pumpWidget(wrap(const BrutalProgressBar(value: 1.5)));
    final fractional = tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox));
    expect(fractional.widthFactor, 1.0);
  });

  testWidgets('BrutalProgressBar uses tokens.green for fill', (tester) async {
    await tester.pumpWidget(wrap(const BrutalProgressBar(value: 0.5)));
    final fillContainer = tester.widgetList<Container>(find.byType(Container)).last;
    final decoration = fillContainer.decoration as BoxDecoration;
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    expect(decoration.color, tokens.green);
  });

  testWidgets('BrutalProgressBar default height is 3px', (tester) async {
    await tester.pumpWidget(wrap(const BrutalProgressBar(value: 0.5)));
    final box = tester.getSize(find.byType(BrutalProgressBar));
    expect(box.height, 3);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/brutal_progress_bar_test.dart`
Expected: FAIL — `brutal_progress_bar.dart` not found.

- [ ] **Step 3: Implement BrutalProgressBar**

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

/// Square-cornered solid-fill progress bar. No gradient, no glow.
class BrutalProgressBar extends StatelessWidget {
  final double value;
  final double height;

  const BrutalProgressBar({
    super.key,
    required this.value,
    this.height = 3,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final clamped = value.clamp(0.0, 1.0);
    return Container(
      height: height,
      color: tc.border,
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: clamped,
          child: Container(color: tc.green),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/brutal_progress_bar_test.dart`
Expected: PASS — 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/brutal/brutal_progress_bar.dart tally_coding_app/test/widgets/brutal/brutal_progress_bar_test.dart
git commit -m "[brutal] BrutalProgressBar widget (solid fill, square)"
```

---

### Task 13: BrutalButton widget (primary + outline)

**Files:**
- Create: `tally_coding_app/lib/widgets/brutal/brutal_button.dart`
- Create: `tally_coding_app/test/widgets/brutal/brutal_button_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal_button.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: child),
    );
  }

  testWidgets('BrutalButton.primary renders label uppercase', (tester) async {
    await tester.pumpWidget(wrap(
      BrutalButton.primary(label: '2 decimals', onPressed: () {}),
    ));
    expect(find.text('2 DECIMALS'), findsOneWidget);
  });

  testWidgets('BrutalButton.outline renders with transparent bg', (tester) async {
    await tester.pumpWidget(wrap(
      BrutalButton.outline(label: 'keep 4', onPressed: () {}),
    ));
    final container = tester.widgetList<Container>(find.byType(Container)).first;
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, isNull);
  });

  testWidgets('BrutalButton invokes onPressed when tapped', (tester) async {
    int taps = 0;
    await tester.pumpWidget(wrap(
      BrutalButton.primary(label: 'tap', onPressed: () => taps++),
    ));
    await tester.tap(find.byType(BrutalButton));
    expect(taps, 1);
  });

  testWidgets('BrutalButton has square corners', (tester) async {
    await tester.pumpWidget(wrap(
      BrutalButton.primary(label: 'x', onPressed: () {}),
    ));
    final container = tester.widgetList<Container>(find.byType(Container)).first;
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.zero);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/brutal_button_test.dart`
Expected: FAIL — `brutal_button.dart` not found.

- [ ] **Step 3: Implement BrutalButton**

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

enum _ButtonStyle { primary, outline }

/// Square uppercase mono button. Two variants: primary (solid green) and
/// outline (1px border, transparent fill).
class BrutalButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final _ButtonStyle _style;
  final double height;

  const BrutalButton.primary({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = 36,
  }) : _style = _ButtonStyle.primary;

  const BrutalButton.outline({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = 36,
  }) : _style = _ButtonStyle.outline;

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final isPrimary = _style == _ButtonStyle.primary;

    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: height,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isPrimary ? tc.green : null,
          border: isPrimary
              ? null
              : Border.all(color: tc.border, width: 1),
          borderRadius: BorderRadius.zero,
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: isPrimary ? tc.bg : tc.fg,
            fontWeight: FontWeight.w700,
            fontSize: 12,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/brutal_button_test.dart`
Expected: PASS — 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/brutal/brutal_button.dart tally_coding_app/test/widgets/brutal/brutal_button_test.dart
git commit -m "[brutal] BrutalButton widget (primary + outline, uppercase mono)"
```

---

### Task 14: BrutalPill widget

**Files:**
- Create: `tally_coding_app/lib/widgets/brutal/brutal_pill.dart`
- Create: `tally_coding_app/test/widgets/brutal/brutal_pill_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal_pill.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: child),
    );
  }

  testWidgets('BrutalPill renders uppercase label', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalPill(label: '1 esc'),
    ));
    expect(find.text('1 ESC'), findsOneWidget);
  });

  testWidgets('BrutalPill defaults to red accent color', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalPill(label: 'x'),
    ));
    final container = tester.widget<Container>(find.byType(Container));
    final decoration = container.decoration as BoxDecoration;
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    expect(decoration.border!.top.color, tokens.red);
  });

  testWidgets('BrutalPill accepts custom accent color', (tester) async {
    await tester.pumpWidget(wrap(
      BrutalPill(label: 'x', accent: themeCatalog[defaultThemeSlug]!.tokens.green),
    ));
    final container = tester.widget<Container>(find.byType(Container));
    final decoration = container.decoration as BoxDecoration;
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    expect(decoration.border!.top.color, tokens.green);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/brutal_pill_test.dart`
Expected: FAIL — `brutal_pill.dart` not found.

- [ ] **Step 3: Implement BrutalPill**

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

/// 1px-bordered, transparent-bg pill with uppercase mono text.
/// Defaults to red accent (escalation/alert); override via `accent`.
class BrutalPill extends StatelessWidget {
  final String label;
  final Color? accent;

  const BrutalPill({super.key, required this.label, this.accent});

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final color = accent ?? tc.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: null,
        border: Border.all(color: color, width: 1),
        borderRadius: BorderRadius.zero,
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/brutal_pill_test.dart`
Expected: PASS — 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/brutal/brutal_pill.dart tally_coding_app/test/widgets/brutal/brutal_pill_test.dart
git commit -m "[brutal] BrutalPill widget (1px border + uppercase mono text)"
```

---

### Task 15: TallyAvatar widget

**Files:**
- Create: `tally_coding_app/lib/widgets/brutal/tally_avatar.dart`
- Create: `tally_coding_app/test/widgets/brutal/tally_avatar_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/cursor_blink.dart';
import 'package:tally_coding_app/widgets/brutal/tally_avatar.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: child),
    );
  }

  testWidgets('TallyAvatar renders T monogram', (tester) async {
    await tester.pumpWidget(wrap(const TallyAvatar()));
    expect(find.text('T'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink()); // dispose timer
  });

  testWidgets('TallyAvatar uses green bg from tokens', (tester) async {
    await tester.pumpWidget(wrap(const TallyAvatar()));
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    final container = tester.widgetList<Container>(find.byType(Container)).first;
    expect(container.color, tokens.green);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TallyAvatar shows badge with CursorBlink when online', (tester) async {
    await tester.pumpWidget(wrap(const TallyAvatar(online: true)));
    expect(find.byType(CursorBlink), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TallyAvatar hides badge when online=false', (tester) async {
    await tester.pumpWidget(wrap(const TallyAvatar(online: false)));
    expect(find.byType(CursorBlink), findsNothing);
  });

  testWidgets('TallyAvatar is square (radius 0)', (tester) async {
    await tester.pumpWidget(wrap(const TallyAvatar()));
    final container = tester.widgetList<Container>(find.byType(Container)).first;
    expect(container.decoration, isNull); // bg via color prop, no decoration
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/tally_avatar_test.dart`
Expected: FAIL — `tally_avatar.dart` not found.

- [ ] **Step 3: Implement TallyAvatar**

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/brutal/cursor_blink.dart';

/// Tally identity: solid green square block with "T" monogram.
/// Optional green cursor-blink badge in the bottom-right corner when online.
class TallyAvatar extends StatelessWidget {
  final double size;
  final bool online;

  const TallyAvatar({super.key, this.size = 28, this.online = true});

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final badgeSize = (size * 0.32).clamp(7.0, 14.0);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            color: tc.green,
            alignment: Alignment.center,
            child: Text(
              'T',
              style: TextStyle(
                color: tc.bg,
                fontWeight: FontWeight.w700,
                fontSize: size * 0.46,
                letterSpacing: -0.5,
                height: 1,
              ),
            ),
          ),
          if (online)
            Positioned(
              right: -1,
              bottom: -1,
              child: CursorBlink(
                child: Container(
                  width: badgeSize,
                  height: badgeSize,
                  color: tc.green,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/tally_avatar_test.dart`
Expected: PASS — 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/brutal/tally_avatar.dart tally_coding_app/test/widgets/brutal/tally_avatar_test.dart
git commit -m "[brutal] TallyAvatar widget (green block + T + cursor blink badge)"
```

---

### Task 16: AgentAvatar widget

**Files:**
- Create: `tally_coding_app/lib/widgets/brutal/agent_avatar.dart`
- Create: `tally_coding_app/test/widgets/brutal/agent_avatar_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/agent_avatar.dart';
import 'package:tally_coding_app/widgets/brutal/cursor_blink.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: child),
    );
  }

  testWidgets('AgentAvatar.architect renders A in magenta', (tester) async {
    await tester.pumpWidget(wrap(
      const AgentAvatar(role: AgentRole.architect, active: false),
    ));
    expect(find.text('A'), findsOneWidget);
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    final container = tester.widgetList<Container>(find.byType(Container)).first;
    expect(container.color, tokens.magenta);
  });

  testWidgets('AgentAvatar.coder renders C in cyan', (tester) async {
    await tester.pumpWidget(wrap(
      const AgentAvatar(role: AgentRole.coder, active: false),
    ));
    expect(find.text('C'), findsOneWidget);
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    final container = tester.widgetList<Container>(find.byType(Container)).first;
    expect(container.color, tokens.cyan);
  });

  testWidgets('AgentAvatar.reader renders R in yellow', (tester) async {
    await tester.pumpWidget(wrap(
      const AgentAvatar(role: AgentRole.reader, active: false),
    ));
    expect(find.text('R'), findsOneWidget);
  });

  testWidgets('AgentAvatar.tester renders T in orange', (tester) async {
    await tester.pumpWidget(wrap(
      const AgentAvatar(role: AgentRole.tester, active: false),
    ));
    expect(find.text('T'), findsOneWidget);
  });

  testWidgets('AgentAvatar shows cursor blink when active', (tester) async {
    await tester.pumpWidget(wrap(
      const AgentAvatar(role: AgentRole.coder, active: true),
    ));
    expect(find.byType(CursorBlink), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('AgentAvatar hides cursor blink when inactive', (tester) async {
    await tester.pumpWidget(wrap(
      const AgentAvatar(role: AgentRole.coder, active: false),
    ));
    expect(find.byType(CursorBlink), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/agent_avatar_test.dart`
Expected: FAIL — `agent_avatar.dart` not found.

- [ ] **Step 3: Implement AgentAvatar**

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/brutal/cursor_blink.dart';

enum AgentRole { architect, coder, reader, tester }

/// Agent identity: ANSI-tinted square block with monogram letter.
/// Active state shows a tiny green cursor in the bottom-right corner
/// (single pixel-square, terminal cursor blink).
class AgentAvatar extends StatelessWidget {
  final AgentRole role;
  final bool active;
  final double size;

  const AgentAvatar({
    super.key,
    required this.role,
    this.active = true,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final (color, mono) = switch (role) {
      AgentRole.architect => (tc.magenta, 'A'),
      AgentRole.coder => (tc.cyan, 'C'),
      AgentRole.reader => (tc.yellow, 'R'),
      AgentRole.tester => (tc.orange, 'T'),
    };
    final cursorSize = (size * 0.20).clamp(3.0, 6.0);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            color: color,
            alignment: Alignment.center,
            child: Text(
              mono,
              style: TextStyle(
                color: tc.bg,
                fontWeight: FontWeight.w700,
                fontSize: size * 0.5,
                letterSpacing: -0.4,
                height: 1,
              ),
            ),
          ),
          if (active)
            Positioned(
              right: 1,
              bottom: 1,
              child: CursorBlink(
                child: Container(
                  width: cursorSize,
                  height: cursorSize,
                  color: tc.green,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/agent_avatar_test.dart`
Expected: PASS — 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/brutal/agent_avatar.dart tally_coding_app/test/widgets/brutal/agent_avatar_test.dart
git commit -m "[brutal] AgentAvatar widget (ANSI block + monogram + active cursor)"
```

---

### Task 17: Brutal widget barrel export

**Files:**
- Create: `tally_coding_app/lib/widgets/brutal/brutal.dart`

- [ ] **Step 1: Create barrel**

```dart
export 'agent_avatar.dart';
export 'brutal_bubble.dart';
export 'brutal_button.dart';
export 'brutal_card.dart';
export 'brutal_pill.dart';
export 'brutal_progress_bar.dart';
export 'cursor_blink.dart';
export 'tally_avatar.dart';
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tally_coding_app && flutter analyze lib/widgets/brutal/brutal.dart`
Expected: "No issues found!"

- [ ] **Step 3: Commit**

```bash
git add tally_coding_app/lib/widgets/brutal/brutal.dart
git commit -m "[brutal] barrel export for widgets/brutal/ module"
```

---

### Task 18: Golden test harness — primitives × themes matrix

**Files:**
- Create: `tally_coding_app/test/widgets/brutal/golden_test_helper.dart`
- Create: `tally_coding_app/test/widgets/brutal/golden_test.dart`

Golden tests render each primitive widget against a representative set of themes (Tokyo Night + Solarized Light to cover dark + light) and compare against committed baseline `.png` files. Catches accidental palette regressions.

- [ ] **Step 1: Create the helper**

Create `tally_coding_app/test/widgets/brutal/golden_test_helper.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/theme.dart';

/// Wrap a widget in a sized scaffold using the named theme's tokens.
Widget themedScaffold(String themeSlug, Widget widget, {Size size = const Size(300, 100)}) {
  final tokens = themeCatalog[themeSlug]!.tokens;
  return MediaQuery(
    data: MediaQueryData(size: size, devicePixelRatio: 1.0),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: themeFromTokens(tokens),
      home: Scaffold(
        body: Center(child: SizedBox(width: size.width, child: widget)),
      ),
    ),
  );
}

/// Subset of themes used for golden tests. Tokyo Night (default dark) and
/// Solarized Light (representative light) catch the dark/light split.
const goldenThemes = ['tokyo-night', 'solarized-light'];
```

- [ ] **Step 2: Write golden tests**

Create `tally_coding_app/test/widgets/brutal/golden_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';
import 'golden_test_helper.dart';

void main() {
  for (final theme in goldenThemes) {
    group('Goldens · $theme', () {
      testWidgets('BrutalCard with text content', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          const BrutalCard(child: Text('Sample card content', style: TextStyle(fontSize: 14))),
        ));
        await expectLater(
          find.byType(BrutalCard),
          matchesGoldenFile('goldens/brutal_card_$theme.png'),
        );
      });

      testWidgets('BrutalBubble', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          const BrutalBubble(child: Text('Diagnosed the bug. Coder is patching.')),
        ));
        await expectLater(
          find.byType(BrutalBubble),
          matchesGoldenFile('goldens/brutal_bubble_$theme.png'),
        );
      });

      testWidgets('BrutalProgressBar at 60%', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          const BrutalProgressBar(value: 0.6),
          size: const Size(200, 20),
        ));
        await expectLater(
          find.byType(BrutalProgressBar),
          matchesGoldenFile('goldens/brutal_progress_$theme.png'),
        );
      });

      testWidgets('BrutalButton.primary', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          BrutalButton.primary(label: '2 decimals', onPressed: () {}),
          size: const Size(160, 50),
        ));
        await expectLater(
          find.byType(BrutalButton),
          matchesGoldenFile('goldens/brutal_button_primary_$theme.png'),
        );
      });

      testWidgets('BrutalPill', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          const BrutalPill(label: '1 esc'),
          size: const Size(100, 30),
        ));
        await expectLater(
          find.byType(BrutalPill),
          matchesGoldenFile('goldens/brutal_pill_$theme.png'),
        );
      });

      testWidgets('TallyAvatar', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          const TallyAvatar(online: false), // disable blink for deterministic capture
          size: const Size(60, 60),
        ));
        await expectLater(
          find.byType(TallyAvatar),
          matchesGoldenFile('goldens/tally_avatar_$theme.png'),
        );
      });

      testWidgets('AgentAvatar.coder', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          const AgentAvatar(role: AgentRole.coder, active: false),
          size: const Size(50, 50),
        ));
        await expectLater(
          find.byType(AgentAvatar),
          matchesGoldenFile('goldens/agent_avatar_coder_$theme.png'),
        );
      });
    });
  }
}
```

- [ ] **Step 3: Generate golden baselines**

Run: `cd tally_coding_app && flutter test --update-goldens test/widgets/brutal/golden_test.dart`
Expected: 14 golden files created in `test/widgets/brutal/goldens/`. Inspect a few visually to confirm they look right (use any image viewer).

- [ ] **Step 4: Run golden tests against committed baselines**

Run: `cd tally_coding_app && flutter test test/widgets/brutal/golden_test.dart`
Expected: PASS — 14 golden tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/test/widgets/brutal/golden_test_helper.dart \
        tally_coding_app/test/widgets/brutal/golden_test.dart \
        tally_coding_app/test/widgets/brutal/goldens/
git commit -m "[brutal] golden test harness (primitives × Tokyo Night + Solarized Light)"
```

---

### Task 19: ThemePickerScreen scaffold + tile widget

**Files:**
- Create: `tally_coding_app/lib/screens/theme_picker_screen.dart`
- Create: `tally_coding_app/test/screens/theme_picker_screen_test.dart`

The picker has two panes: left list of theme tiles (with 4 swatches each), right preview pane showing live Brutal Terminal components in the selected theme. Filter input at top of list. Tap a tile → applies the theme via ThemeController.

- [ ] **Step 1: Write the failing test**

Create `tally_coding_app/test/screens/theme_picker_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tally_coding_app/screens/theme_picker_screen.dart';
import 'package:tally_coding_app/theme/theme.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpPicker(WidgetTester tester) async {
    final controller = ThemeController();
    await controller.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          theme: themeFromTokens(controller.activeEntry.tokens),
          home: const ThemePickerScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders all 28 theme tiles', (tester) async {
    await pumpPicker(tester);
    expect(find.byType(ThemeTile), findsNWidgets(28));
  });

  testWidgets('filter input narrows the list', (tester) async {
    await pumpPicker(tester);
    await tester.enterText(find.byType(TextField), 'catppuccin');
    await tester.pump();
    // Catppuccin has 3 variants: Mocha, Macchiato, Frappé (plus Latte light = 4)
    expect(find.byType(ThemeTile), findsNWidgets(4));
  });

  testWidgets('tapping a tile updates the active theme', (tester) async {
    await pumpPicker(tester);
    final controller = tester.element(find.byType(ThemePickerScreen))
        .read<ThemeController>();
    await tester.tap(find.text('Dracula'));
    await tester.pump();
    expect(controller.activeSlug, 'dracula');
  });

  testWidgets('preview pane renders sample widgets', (tester) async {
    await pumpPicker(tester);
    expect(find.text('Sample · preview reflects active theme'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/screens/theme_picker_screen_test.dart`
Expected: FAIL — `theme_picker_screen.dart` not found.

- [ ] **Step 3: Implement the picker screen**

Create `tally_coding_app/lib/screens/theme_picker_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';

class ThemePickerScreen extends StatefulWidget {
  const ThemePickerScreen({super.key});

  @override
  State<ThemePickerScreen> createState() => _ThemePickerScreenState();
}

class _ThemePickerScreenState extends State<ThemePickerScreen> {
  String _filter = '';

  List<MapEntry<String, ThemeEntry>> get _visibleThemes {
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return themeCatalog.entries.toList();
    return themeCatalog.entries.where((e) {
      final hay = '${e.value.name} ${e.value.desc}'.toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final controller = context.watch<ThemeController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('APPEARANCE · THEME', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.0)),
        backgroundColor: tc.bg,
        elevation: 0,
        foregroundColor: tc.fg,
        shape: Border(bottom: BorderSide(color: tc.border, width: 1)),
      ),
      body: Row(
        children: [
          // LEFT: filter + theme list
          SizedBox(
            width: 340,
            child: Container(
              decoration: BoxDecoration(border: Border(right: BorderSide(color: tc.border, width: 1))),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: TextField(
                      onChanged: (v) => setState(() => _filter = v),
                      decoration: InputDecoration(
                        hintText: 'filter themes…',
                        hintStyle: TextStyle(color: tc.fgXdim, fontSize: 11),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(color: tc.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(color: tc.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(color: tc.fg_xdim ?? tc.fgXdim),
                        ),
                      ),
                      style: TextStyle(fontSize: 11, color: tc.fg),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final entry in _visibleThemes)
                          ThemeTile(
                            slug: entry.key,
                            entry: entry.value,
                            active: entry.key == controller.activeSlug,
                            onTap: () => controller.setTheme(entry.key),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // RIGHT: preview pane
          Expanded(
            child: _PreviewPane(),
          ),
        ],
      ),
    );
  }
}

class ThemeTile extends StatelessWidget {
  final String slug;
  final ThemeEntry entry;
  final bool active;
  final VoidCallback onTap;

  const ThemeTile({
    super.key,
    required this.slug,
    required this.entry,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: active ? tc.cardHov : null,
          border: Border(left: BorderSide(color: active ? tc.green : Colors.transparent, width: 2)),
        ),
        child: Row(
          children: [
            // 4 swatches
            Row(
              children: [
                Container(width: 12, height: 24, color: entry.tokens.bg),
                Container(width: 12, height: 24, color: entry.tokens.fg),
                Container(width: 12, height: 24, color: entry.tokens.green),
                Container(width: 12, height: 24, color: entry.tokens.red),
              ],
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.name, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: tc.fg)),
                  const SizedBox(height: 2),
                  Text(entry.desc, maxLines: 1, overflow: TextOverflow.ellipsis,
                       style: TextStyle(fontSize: 10, color: tc.fgXdim)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewPane extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Container(
      padding: const EdgeInsets.all(36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('PREVIEW',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.0, color: tc.fgXdim)),
          const SizedBox(height: 24),
          Wrap(
            spacing: 22,
            runSpacing: 22,
            children: [
              SizedBox(
                width: 280,
                child: BrutalCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Sample · preview reflects active theme',
                           style: TextStyle(color: tc.fg, fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 11),
                      Row(
                        children: [
                          const AgentAvatar(role: AgentRole.architect, active: false),
                          const SizedBox(width: 4),
                          const AgentAvatar(role: AgentRole.coder, active: true),
                          const Spacer(),
                          Text('~5m left', style: TextStyle(color: tc.fgDim, fontSize: 11)),
                        ],
                      ),
                      const SizedBox(height: 11),
                      const BrutalProgressBar(value: 0.6),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 280,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const TallyAvatar(online: false),
                    const SizedBox(width: 8),
                    Expanded(
                      child: BrutalBubble(
                        child: Text(
                          'Diagnosed the daily-deals bug. Coder is patching — PR in ~5 min.',
                          style: TextStyle(color: tc.fg, fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 280,
                child: Row(
                  children: [
                    Expanded(child: BrutalButton.primary(label: '2 decimals', onPressed: () {})),
                    const SizedBox(width: 8),
                    Expanded(child: BrutalButton.outline(label: 'keep 4', onPressed: () {})),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
```

Note: the test references `find.text('Sample · preview reflects active theme')` — this matches the BrutalCard preview heading.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/screens/theme_picker_screen_test.dart`
Expected: PASS — 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/screens/theme_picker_screen.dart tally_coding_app/test/screens/theme_picker_screen_test.dart
git commit -m "[app] ThemePickerScreen (sidebar list + live preview)"
```

---

### Task 20: Wire Appearance tab into workspace_settings.dart

**Files:**
- Modify: `tally_coding_app/lib/screens/workspace_settings.dart`
- Create: `tally_coding_app/test/screens/workspace_settings_appearance_test.dart`

The existing settings screen has tabs (Branding, Members, Archived Channels). Add an "Appearance" tab that hosts a button to navigate to the ThemePickerScreen.

- [ ] **Step 1: Read current workspace_settings.dart to find the tab structure**

Run: `cd tally_coding_app && grep -n "Tab\|TabBar\|DefaultTabController" lib/screens/workspace_settings.dart | head -20`

Expected: Identify the `TabController` / `TabBar` / `TabBarView` line numbers and the existing tab list.

- [ ] **Step 2: Write the failing test**

Create `tally_coding_app/test/screens/workspace_settings_appearance_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tally_coding_app/screens/theme_picker_screen.dart';
import 'package:tally_coding_app/screens/workspace_settings.dart';
import 'package:tally_coding_app/theme/theme.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Appearance tab is present in workspace settings', (tester) async {
    final controller = ThemeController();
    await controller.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          theme: themeFromTokens(controller.activeEntry.tokens),
          home: const WorkspaceSettingsScreen(workspaceId: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
  });

  testWidgets('Tapping "Open theme picker" navigates to ThemePickerScreen',
      (tester) async {
    final controller = ThemeController();
    await controller.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          theme: themeFromTokens(controller.activeEntry.tokens),
          home: const WorkspaceSettingsScreen(workspaceId: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open theme picker'));
    await tester.pumpAndSettle();
    expect(find.byType(ThemePickerScreen), findsOneWidget);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd tally_coding_app && flutter test test/screens/workspace_settings_appearance_test.dart`
Expected: FAIL — `Appearance` tab not found.

- [ ] **Step 4: Modify workspace_settings.dart**

Add `Appearance` to the tab list. The existing tabs likely look something like:

```dart
DefaultTabController(
  length: 3,
  child: Scaffold(
    appBar: AppBar(
      bottom: TabBar(tabs: [
        Tab(text: 'Branding'),
        Tab(text: 'Members'),
        Tab(text: 'Archived'),
      ]),
    ),
    body: TabBarView(children: [
      _BrandingTab(...),
      _MembersTab(...),
      _ArchivedTab(...),
    ]),
  ),
)
```

Change `length: 3` → `length: 4`, append `Tab(text: 'Appearance')`, append the new tab body:

```dart
_AppearanceTab(),
```

Then add the new `_AppearanceTab` widget at the bottom of the file:

```dart
class _AppearanceTab extends StatelessWidget {
  const _AppearanceTab();

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final controller = context.watch<ThemeController>();
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('THEME', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.0, color: tc.fgXdim)),
          const SizedBox(height: 12),
          Text(controller.activeEntry.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: tc.fg)),
          const SizedBox(height: 4),
          Text(controller.activeEntry.desc, style: TextStyle(fontSize: 12, color: tc.fgDim)),
          const SizedBox(height: 20),
          BrutalButton.primary(
            label: 'Open theme picker',
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ThemePickerScreen(),
              ));
            },
          ),
        ],
      ),
    );
  }
}
```

Add the new imports at the top of `workspace_settings.dart`:

```dart
import 'package:provider/provider.dart';
import 'package:tally_coding_app/screens/theme_picker_screen.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd tally_coding_app && flutter test test/screens/workspace_settings_appearance_test.dart`
Expected: PASS — 2 tests pass.

Also run: `cd tally_coding_app && flutter test test/screens/workspace_settings_screen_test.dart`
Expected: existing settings tests still pass (no regressions).

- [ ] **Step 6: Commit**

```bash
git add tally_coding_app/lib/screens/workspace_settings.dart tally_coding_app/test/screens/workspace_settings_appearance_test.dart
git commit -m "[app] add Appearance tab + theme picker link to workspace settings"
```

---

### Task 21: Add Dart/Flutter MCP server + agent skills config

**Files:**
- Create: `tally_coding_app/.mcp.json`
- Create: `tally_coding_app/CLAUDE.md`

Flutter 3.44 ships the Dart/Flutter MCP server + agent skills for grounding agents in framework best-practices + hot-reload-via-agent. Install both for our dev workflow on this app.

- [ ] **Step 1: Look up the MCP server install command**

Run: `dart pub global activate dart_mcp_server 2>&1 | head -20`

(If the package name is different in your local Dart SDK, use `dart pub global list` to find candidates, or check the official Dart docs at https://dart.dev/tools/mcp-server. Update the activate command accordingly. As of Flutter 3.44 release the canonical name is `dart_mcp_server`.)

Expected: package activated or "Already activated" message.

- [ ] **Step 2: Create .mcp.json**

```json
{
  "mcpServers": {
    "dart": {
      "command": "dart",
      "args": ["mcp-server"]
    }
  }
}
```

- [ ] **Step 3: Create CLAUDE.md for tally_coding_app**

```markdown
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

## What B1 ships vs what's deferred

B1 ships the design system + theme picker. B2/B3/B4/B5 will rewire existing screens (discord_shell.dart, general_channel.dart, task_channel.dart, etc.) to use Brutal primitives — those screens will still look like the old Material-default app after B1 lands. That's by design: B1 is foundation.
```

- [ ] **Step 4: Verify MCP server config is valid**

Run: `cd tally_coding_app && cat .mcp.json | python3 -m json.tool`
Expected: re-prints the JSON with no errors.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/.mcp.json tally_coding_app/CLAUDE.md
git commit -m "[app] add Dart MCP server config + CLAUDE.md for tally_coding_app"
```

---

### Task 22: Update spec acceptance criteria + final verification

**Files:**
- Modify: `docs/superpowers/specs/2026-05-22-ux-operator-journey-design.md`

- [ ] **Step 1: Run the full test suite**

Run: `cd tally_coding_app && flutter test`
Expected: ALL tests pass (existing + new). No failures, no skipped tests.

- [ ] **Step 2: Run analyzer for sanity check**

Run: `cd tally_coding_app && flutter analyze`
Expected: "No issues found!" or only pre-existing issues unrelated to B1 work.

- [ ] **Step 3: Manual smoke test of theme picker**

Run: `cd tally_coding_app && flutter run -d linux`

In the app:
1. Navigate to workspace settings (existing gear-icon flow)
2. Tap the Appearance tab
3. Tap "Open theme picker"
4. Filter for "catppuccin" — should show 4 themes
5. Tap "Catppuccin Mocha" — the picker preview should re-render in Mocha colors
6. Close the picker (back button); the app's main surfaces should also be in Mocha
7. Quit the app, re-launch — should still be in Mocha (SharedPreferences persistence)

Expected: all steps work.

- [ ] **Step 4: Update spec acceptance criteria**

In `docs/superpowers/specs/2026-05-22-ux-operator-journey-design.md`, section 13:

Add after the existing `- [x]` lines:
```markdown
- [x] Sub-project B1 (design system + theme picker) plan written: `docs/superpowers/plans/2026-05-25-sub-project-b1-design-system-and-theme-picker.md`
```

(The `writing-plans skill invoked` checkbox stays unchecked until B2-B5 are also planned.)

- [ ] **Step 5: Final commit**

```bash
git add docs/superpowers/specs/2026-05-22-ux-operator-journey-design.md
git commit -m "[docs] mark B1 plan written in spec acceptance criteria"
```

---

## Self-Review (post-write)

Run through these before declaring the plan complete:

**1. Spec coverage:**
- ✓ Brutal Terminal token system → Task 2
- ✓ ThemeData builder → Task 3
- ✓ Tokyo Night default → Task 4
- ✓ All 28 themes → Task 5
- ✓ ThemeController + persistence → Task 6
- ✓ JetBrains Mono via google_fonts → Task 1 + Task 3
- ✓ Cursor blink animation → Task 9
- ✓ All 9 Brutal widget primitives → Tasks 10-16 + Task 9 (cursor blink) + Task 17 (barrel)
- ✓ Theme picker UI → Task 19
- ✓ Settings integration → Task 20
- ✓ Golden test harness → Task 18
- ✓ Dart MCP + CLAUDE.md dev tooling → Task 21
- ✓ main.dart wiring → Task 8
- ✓ Final verification + acceptance → Task 22

Gaps: BrutalText was originally listed but is now handled via `ThemeData.textTheme` (Task 3) — no separate widget needed. ✓

**2. Placeholder scan:** None found. All steps have explicit code, exact commands, exact expected output.

**3. Type consistency:**
- `TCTokens` named consistently (Task 2 → all widget tasks)
- `context.tc` accessor (Task 2) used in Tasks 10-16, 19, 20
- `AgentRole` enum (Task 16) — used in Task 19 preview pane
- `ThemeController.activeSlug` / `.activeEntry` / `.setTheme()` consistent (Tasks 6, 8, 19, 20)
- `defaultThemeSlug` const (Task 4) — used in all widget tests
- `themeCatalog` map (Task 4) — used everywhere

**4. Order dependencies:**
- Task 1 (pubspec deps) → all later tasks
- Tasks 2 → 3 → 4 → 5 → 6 → 7 → 8 (theme foundation chain)
- Task 9 (CursorBlink) → Tasks 15, 16 (Tally/Agent avatars)
- Tasks 10-16 (widget primitives) → Task 17 (barrel) → Tasks 18, 19, 20 (consumers)
- Task 21 can land any time
- Task 22 is last

Dependencies clean. No forward references.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-25-sub-project-b1-design-system-and-theme-picker.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
