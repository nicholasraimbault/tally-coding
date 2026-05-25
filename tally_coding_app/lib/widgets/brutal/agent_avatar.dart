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
