# Claude Design — Tally Coding mockups

8 reference mockups + the shared design system, generated through
[Claude Design](https://claude.ai/design) (April 2026 launch). Source of
truth for the visual design that drives Flutter implementation.

## Visual identity

- **Structure: Brutal Terminal.** JetBrains Mono everywhere, square corners,
  1px hairlines, no gradients, no shadows, ANSI-mapped agent colors.
- **Default theme: Tokyo Night** (`#1a1b26` bg, `#c0caf5` fg, `#9ece6a`
  green, `#f7768e` coral, `#7dcfff` cyan, `#bb9af7` magenta).
- **In-app theme picker** ships with a curated library of 28 terminal
  themes (Tokyo Night, Catppuccin variants, Gruvbox, Nord, Dracula,
  Solarized, Rosé Pine, etc.). User picks their theme; we ship Tokyo
  Night as default. See Settings → Appearance → Theme. Theme catalog
  reference lives in the spec at
  `docs/superpowers/specs/2026-05-22-ux-operator-journey-design.md`.

## File map

| File | Surface |
|---|---|
| `tc-shared.jsx` | Design system: TC tokens + primitive components (avatars, cards, progress bars, headers, sheets, escalation chrome) |
| `ios-frame.jsx` | iOS device frame (status bar, dynamic island, home indicator) used by mobile mockups |
| `screen1.jsx` + `Tally Coding - Screen 1.html` | Mobile · 5-col kanban + ambient mini dash |
| `screen2.jsx` + `... Screen 2.html` | Mobile · escalation takeover (bottom sheet) |
| `screen3.jsx` + `... Screen 3.html` | Mobile · channels sheet expanded (rich variant) |
| `screen3-v1.jsx` | Backup: rounded-flat variant from before the rich-row pass (kept for reference only; not loaded by any HTML) |
| `screen4.jsx` + `... Screen 4.html` | Mobile · task channel chat |
| `screen5.jsx` + `... Screen 5.html` | Mobile · long-term channel chat with inline escalation card |
| `screen6.jsx` + `... Screen 6.html` | Desktop · ambient (1440×900, sidebar + kanban) |
| `screen7.jsx` + `... Screen 7.html` | Desktop · escalation takeover (sidebar mini-dash flipped) |
| `screen8.jsx` + `... Screen 8.html` | iOS · lock-screen push notification (system chrome exception) |

## How to view

The HTML files Babel-compile the JSX in the browser. Serve them via any
local HTTP server (file://-style loading is blocked by CORS for JSX).

```sh
cd docs/design/claude-design
python3 -m http.server 59820
# then open http://localhost:59820/Tally%20Coding%20-%20Screen%201.html
```

Or any other port / server you prefer.

## Architecture lock

These mockups crystallize the architecture locked in the v17 brainstorm
session (see spec). Structural decisions reflected here:

- **5-column kanban**: `To do · Planning · Running · Awaiting · Done`
- **No FAB**: inline `+ New task` ghost row at the bottom of each column
  (Notion mobile pattern)
- **Task channels never appear in the channel list** — only via Kanban
  card tap
- **Long-term channels only in the channel list** (`#general`, `#health`,
  `#planning`, custom)
- **Escalation routing**: agents → task channel → Tally → long-term
  channel → user
- **Escalation surfaces in 3 places**: mobile bottom-sheet takeover
  (Screen 2), inline card in long-term channel (Screen 5), desktop
  sidebar mini-dash takeover (Screen 7)
- **Tally is ambient in every channel** — no dedicated DM
- **Tally identity**: solid green block + "T" monogram + terminal cursor
  blink badge (no gradient, no pulsing glow)
- **Agent identity**: ANSI-mapped solid color blocks + monogram letters
  (architect=magenta A, coder=cyan C, reader=yellow R, tester=orange T) —
  no emoji glyphs

## Flutter implementation notes

Components in `tc-shared.jsx` translate to Flutter widgets 1:1. The
`TC` token object maps to a `ThemeData` extension; `FONT`/`MONO` map to
`TextTheme` configuration. The brutal terminal structural rules
(`borderRadius: 0` everywhere except drag handles + iOS notification
chrome) become a project-wide lint or shared `BrutalCard` /
`BrutalButton` widget set.

For the theme picker, the 28-theme catalog should be stored as a JSON
manifest (or compile-time Dart const map) that maps theme keys to a
flat token set. `ThemeData` is generated from the active theme's tokens
at runtime; user preference persists to local storage.

iOS lock-screen notification (Screen 8) is OS chrome — corner radius,
glassmorphic background, and SF font are iOS-native and exempt from
Brutal Terminal rules. Only the Tally app icon (solid green block +
"T") and the action button accent (TC.green) follow our system.
