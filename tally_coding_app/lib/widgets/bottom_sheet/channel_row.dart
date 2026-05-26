import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_model.dart';

/// A calm (no escalation pending) channel row for use in ChannelsSheet.
///
/// Shows the channel name prefixed with `#` and, if available, the last
/// message snippet below it.
///
/// Example:
/// ```dart
/// CalmChannelRow(
///   channel: ChannelModel(id: 1, name: 'general', kind: 'custom',
///       lastMessageText: 'p99 OK at 240ms'),
///   onTap: () {},
/// )
/// ```
class CalmChannelRow extends StatelessWidget {
  final ChannelModel channel;
  final VoidCallback onTap;

  const CalmChannelRow({super.key, required this.channel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tc.border, width: 1)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '#${channel.name}',
                    style: TextStyle(
                      color: tc.fg,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (channel.lastMessageText != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      channel.lastMessageText!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tc.fgDim, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
