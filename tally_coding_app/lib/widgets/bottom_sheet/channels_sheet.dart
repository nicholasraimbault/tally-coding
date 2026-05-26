import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_model.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_row.dart';

/// Expanded channels sheet — shown when the bottom sheet is in
/// `channelsExpanded` state (swipe-up from AmbientMiniDash).
///
/// Renders only long-term channels (those where [ChannelModel.isLongTerm] is
/// true). Task channels are filtered out. Channels in [needsAttention] get the
/// [NeedsAttentionChannelRow] treatment; all others use [CalmChannelRow].
///
/// Example:
/// ```dart
/// ChannelsSheet(
///   channels: controller.channels,
///   needsAttention: {7},
///   escalationCountByChannel: {7: 2},
///   onChannelTap: (ch) => openChannel(ch.id),
///   onCollapse: controller.collapseToAmbient,
/// )
/// ```
class ChannelsSheet extends StatelessWidget {
  final List<ChannelModel> channels;
  final Set<int> needsAttention;
  final Map<int, int> escalationCountByChannel;
  final void Function(ChannelModel) onChannelTap;
  final VoidCallback onCollapse;

  const ChannelsSheet({
    super.key,
    required this.channels,
    required this.needsAttention,
    required this.escalationCountByChannel,
    required this.onChannelTap,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final longTerm = channels.where((c) => c.isLongTerm).toList();
    final attentionCount =
        longTerm.where((c) => needsAttention.contains(c.id)).length;

    return Container(
      decoration: BoxDecoration(
        color: tc.sheet,
        border: Border(top: BorderSide(color: tc.border, width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle — tap to collapse
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: GestureDetector(
              onTap: onCollapse,
              behavior: HitTestBehavior.opaque,
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: tc.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          // Header: "CHANNELS" label + count badge + optional attention note
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Text(
                  'CHANNELS',
                  style: TextStyle(
                    color: tc.fgDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(color: tc.border, width: 1),
                  ),
                  child: Text(
                    '${longTerm.length}',
                    style: TextStyle(
                      color: tc.fgXdim,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (attentionCount > 0) ...[
                  const Spacer(),
                  Text(
                    '$attentionCount NEED${attentionCount == 1 ? "S" : ""} YOU',
                    style: TextStyle(
                      color: tc.red,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Activity strip — shows channel count; B4 will surface narrator counts
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '${longTerm.length} channels',
              style: TextStyle(color: tc.fgXdim, fontSize: 11),
            ),
          ),
          // Channel rows
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 480),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: longTerm.length,
              itemBuilder: (ctx, i) {
                final ch = longTerm[i];
                if (needsAttention.contains(ch.id)) {
                  return NeedsAttentionChannelRow(
                    channel: ch,
                    escalationCount: escalationCountByChannel[ch.id] ?? 1,
                    onTap: () => onChannelTap(ch),
                  );
                }
                return CalmChannelRow(
                  channel: ch,
                  onTap: () => onChannelTap(ch),
                );
              },
            ),
          ),
          // iOS safe-area bottom padding
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
