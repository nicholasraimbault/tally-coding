import 'package:flutter/material.dart';
import '../../theme/tc_tokens.dart';

/// A single long-term channel entry for the desktop sidebar.
///
/// [needsAttention] = escalation pending. [escalationCount] drives the pill.
@immutable
class SidebarChannelEntry {
  final String name;
  final bool needsAttention;
  final int escalationCount;
  const SidebarChannelEntry({
    required this.name,
    required this.needsAttention,
    required this.escalationCount,
  });
}

/// Compact 1-line channel list for the desktop sidebar.
///
/// Shows:
/// - Section header "CHANNELS" + count + `+` adder button
/// - One row per [SidebarChannelEntry]: `＃` icon + name (+ needs-attention
///   treatment: 3 px coral left accent + coral row tint + count pill + chevron)
///
/// Active channel (matching [activeChannelName]) gets a subtle `rgba(tc.fg, 0.04)`
/// background tint.
///
/// Example:
/// ```dart
/// SidebarChannelsList(
///   channels: channels,
///   activeChannelName: 'general',
///   onChannelTap: (name) => setState(() => _activeChannel = name),
///   onAddChannel: () => _showNewChannelModal(context),
/// )
/// ```
class SidebarChannelsList extends StatelessWidget {
  final List<SidebarChannelEntry> channels;
  final String? activeChannelName;
  final void Function(String name) onChannelTap;
  final VoidCallback onAddChannel;

  const SidebarChannelsList({
    super.key,
    required this.channels,
    required this.activeChannelName,
    required this.onChannelTap,
    required this.onAddChannel,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          tc: tc,
          count: channels.length,
          onAdd: onAddChannel,
        ),
        for (final ch in channels)
          _ChannelRow(
            entry: ch,
            isActive: ch.name == activeChannelName,
            tc: tc,
            onTap: () => onChannelTap(ch.name),
          ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final TCTokens tc;
  final int count;
  final VoidCallback onAdd;
  const _SectionHeader(
      {required this.tc, required this.count, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Row(
        children: [
          Text(
            'CHANNELS',
            style: TextStyle(
              color: tc.fgXdim,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              fontFamily: 'JetBrainsMono',
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: tc.border, width: 1),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: tc.fgXdim,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ),
          const Spacer(),
          GestureDetector(
            key: const Key('sidebar_channels_add'),
            onTap: onAdd,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: SizedBox(
                width: 22,
                height: 22,
                child: Center(
                  child: Text(
                    '+',
                    style: TextStyle(
                      color: tc.fgXdim,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'JetBrainsMono',
                      height: 1,
                    ),
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

class _ChannelRow extends StatefulWidget {
  final SidebarChannelEntry entry;
  final bool isActive;
  final TCTokens tc;
  final VoidCallback onTap;
  const _ChannelRow({
    required this.entry,
    required this.isActive,
    required this.tc,
    required this.onTap,
  });

  @override
  State<_ChannelRow> createState() => _ChannelRowState();
}

class _ChannelRowState extends State<_ChannelRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final ch = widget.entry;

    if (ch.needsAttention) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Stack(
            children: [
              // Row background (coral tint)
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                color: _hovered
                    ? const Color(0x14F7768E) // rgba(247,118,142,0.08)
                    : const Color(0x0DF7768E), // rgba(247,118,142,0.05)
                padding: const EdgeInsets.fromLTRB(17, 7, 14, 7),
                child: Row(
                  children: [
                    Text(
                      '＃',
                      style: TextStyle(
                        color: tc.red,
                        fontSize: 13,
                        height: 1,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ch.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tc.fg,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'JetBrainsMono',
                        ),
                      ),
                    ),
                    if (ch.escalationCount > 0) ...[
                      const SizedBox(width: 4),
                      Container(
                        constraints: const BoxConstraints(minWidth: 18),
                        height: 18,
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          border: Border.all(color: tc.red, width: 1),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${ch.escalationCount}',
                          style: TextStyle(
                            color: tc.red,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'JetBrainsMono',
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 4),
                    // Chevron-right in coral
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CustomPaint(
                          painter: _ChevronRightPainter(color: tc.red)),
                    ),
                  ],
                ),
              ),
              // 3 px coral left accent bar
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 3.0),
                  width: 3,
                  color: tc.red,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Normal channel row
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          color: widget.isActive
              ? Color.fromRGBO(tc.fg.r.toInt(), tc.fg.g.toInt(), tc.fg.b.toInt(), 0.06)
              : (_hovered
                  ? Color.fromRGBO(
                      tc.fg.r.toInt(), tc.fg.g.toInt(), tc.fg.b.toInt(), 0.04)
                  : Colors.transparent),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            children: [
              Text(
                '＃',
                style: TextStyle(
                  color: tc.fgXdim,
                  fontSize: 13,
                  height: 1,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ch.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _hovered || widget.isActive ? tc.fg : tc.fgDim,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChevronRightPainter extends CustomPainter {
  final Color color;
  _ChevronRightPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(size.width * 0.25, size.height * 0.1)
      ..lineTo(size.width * 0.75, size.height * 0.5)
      ..lineTo(size.width * 0.25, size.height * 0.9);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ChevronRightPainter old) => old.color != color;
}
