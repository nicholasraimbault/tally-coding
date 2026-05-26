import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

enum _ButtonStyle { primary, outline }

/// Square-cornered button with JetBrains Mono Bold uppercase label.
///
/// Two variants:
/// - `BrutalButton.primary` — solid `tc.green` background, `tc.bg` text.
/// - `BrutalButton.outline` — transparent background, 1px `tc.border` border,
///   `tc.fg` text.
///
/// When `onPressed == null` the button renders at 50% opacity and taps are
/// no-ops (GestureDetector with null onTap does nothing).
///
/// Example:
/// ```dart
/// BrutalButton.primary(label: 'Deploy', onPressed: () => deploy())
/// BrutalButton.outline(label: 'Cancel', onPressed: () => cancel())
/// BrutalButton.primary(label: 'Save', onPressed: null) // disabled state
/// ```
class BrutalButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final double height;
  final _ButtonStyle _style;

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
    final enabled = onPressed != null;

    final Color bgColor =
        _style == _ButtonStyle.primary ? tc.green : Colors.transparent;
    final Color textColor =
        _style == _ButtonStyle.primary ? tc.bg : tc.fg;
    final Border? border = _style == _ButtonStyle.outline
        ? Border.all(color: tc.border, width: 1)
        : null;

    final button = GestureDetector(
      onTap: onPressed,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: bgColor,
            border: border,
            borderRadius: BorderRadius.zero,
          ),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label.toUpperCase(),
            // Inherit font family from theme.textTheme (JetBrains Mono via
            // themeFromTokens), then override size/weight/color. Avoids the
            // need to bundle JetBrainsMono-Bold.ttf separately or call
            // GoogleFonts.jetBrainsMono() which loads each weight on demand.
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                  letterSpacing: 0.5,
                ),
          ),
        ),
      ),
    );

    return enabled ? button : Opacity(opacity: 0.5, child: button);
  }
}
