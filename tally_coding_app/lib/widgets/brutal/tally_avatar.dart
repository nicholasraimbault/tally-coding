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
