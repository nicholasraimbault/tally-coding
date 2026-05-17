import 'package:flutter/material.dart';

/// Shared header for the main-pane channel view (used by #general and
/// each task channel). Matches Discord's bordered top strip.
class ChannelHeader extends StatelessWidget {
  final String glyph;
  final String name;
  final String description;
  final Widget? trailing;
  const ChannelHeader({
    super.key,
    required this.glyph,
    required this.name,
    required this.description,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF313338),
        border: Border(
          bottom: BorderSide(color: Color(0xFF1E1F22), width: 1),
        ),
      ),
      child: Row(
        children: [
          Text(glyph, style: const TextStyle(fontSize: 18, color: Color(0xFF8E9297))),
          const SizedBox(width: 8),
          Text(
            name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            color: const Color(0xFF1E1F22),
          ),
          Expanded(
            child: Text(
              description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF8E9297), fontSize: 13),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
