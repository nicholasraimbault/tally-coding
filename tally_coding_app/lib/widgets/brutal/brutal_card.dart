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
