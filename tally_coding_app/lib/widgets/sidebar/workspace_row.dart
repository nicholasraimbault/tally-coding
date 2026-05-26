import 'package:flutter/material.dart';
import '../../theme/tc_tokens.dart';

/// Top row of the desktop sidebar.
///
/// Shows:
/// - 24×24 green badge with the first letter of [workspaceName] (uppercase)
/// - [workspaceName] in TC.fg bold
/// - Chevron-down (tapping the row area fires [onSwitcherTap])
/// - Search icon button (fires [onSearchTap])
///
/// Example:
/// ```dart
/// WorkspaceRow(
///   workspaceName: 'pronoic',
///   onSwitcherTap: () => _showWorkspacePicker(context),
///   onSearchTap: () => _openSearch(context),
/// )
/// ```
class WorkspaceRow extends StatelessWidget {
  final String workspaceName;
  final VoidCallback onSwitcherTap;
  final VoidCallback onSearchTap;

  const WorkspaceRow({
    super.key,
    required this.workspaceName,
    required this.onSwitcherTap,
    required this.onSearchTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final letter = workspaceName.trim().isEmpty
        ? '?'
        : workspaceName.trim()[0].toUpperCase();

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tc.border, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          // Workspace badge (green block, first letter) + name + chevron
          Expanded(
            child: GestureDetector(
              onTap: onSwitcherTap,
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    color: tc.green,
                    alignment: Alignment.center,
                    child: Text(
                      letter,
                      style: TextStyle(
                        color: tc.bg,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'JetBrainsMono',
                        height: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      workspaceName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tc.fg,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Chevron-down (square linecap, no fill)
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CustomPaint(
                        painter: _ChevronPainter(color: tc.fgXdim)),
                  ),
                ],
              ),
            ),
          ),
          // Search icon button
          GestureDetector(
            key: const Key('workspace_row_search'),
            onTap: onSearchTap,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: SizedBox(
                width: 26,
                height: 26,
                child: Center(
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CustomPaint(
                        painter: _SearchPainter(color: tc.fgXdim)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws a chevron-down with square line caps.
class _ChevronPainter extends CustomPainter {
  final Color color;
  _ChevronPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(size.width * 0.15, size.height * 0.35)
      ..lineTo(size.width * 0.5, size.height * 0.7)
      ..lineTo(size.width * 0.85, size.height * 0.35);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ChevronPainter old) => old.color != color;
}

/// Draws a search (circle + handle line) icon with square line caps.
class _SearchPainter extends CustomPainter {
  final Color color;
  _SearchPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;
    // Circle
    canvas.drawCircle(
      Offset(size.width * 0.44, size.height * 0.44),
      size.width * 0.3,
      paint,
    );
    // Handle line
    canvas.drawLine(
      Offset(size.width * 0.66, size.height * 0.66),
      Offset(size.width * 0.92, size.height * 0.92),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SearchPainter old) => old.color != color;
}
