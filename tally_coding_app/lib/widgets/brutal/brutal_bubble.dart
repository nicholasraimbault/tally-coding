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
