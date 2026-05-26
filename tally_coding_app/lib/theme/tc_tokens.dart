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
