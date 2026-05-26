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
