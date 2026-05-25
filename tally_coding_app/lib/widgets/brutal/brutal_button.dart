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
/// Example:
/// ```dart
/// BrutalButton.primary(label: 'Deploy', onPressed: () => deploy())
/// BrutalButton.outline(label: 'Cancel', onPressed: () => cancel())
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

    final Color bgColor =
        _style == _ButtonStyle.primary ? tc.green : Colors.transparent;
    final Color textColor =
        _style == _ButtonStyle.primary ? tc.bg : tc.fg;
    final Border? border = _style == _ButtonStyle.outline
        ? Border.all(color: tc.border, width: 1)
        : null;

    return GestureDetector(
      onTap: onPressed,
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
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontWeight: FontWeight.bold,
            fontSize: 12,
            color: textColor,
          ),
        ),
      ),
    );
  }
}
