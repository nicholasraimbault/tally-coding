import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';

/// Full-height sheet rendered in takeover state.
///
/// Shows coral chrome border, Tally avatar, channel header with
/// "needs you" label, optional queue badge, and the escalation question.
/// Quick reply buttons and the Open/Skip ghost row are added by Task 7.
///
/// Example:
/// ```dart
/// EscalationSheet(
///   escalation: esc,
///   queueIndex: 0, queueSize: 1,
///   taskTitle: 'Fix daily-deals',
///   channelName: 'general',
///   onReply: (option) => controller.resolveActive(),
///   onSkip: controller.skip,
///   onOpen: () {},
/// )
/// ```
class EscalationSheet extends StatelessWidget {
  final EscalationModel escalation;
  final int queueIndex; // 0-based
  final int queueSize;
  final String taskTitle;
  final String channelName;
  final void Function(String option) onReply;
  final VoidCallback onSkip;
  final VoidCallback onOpen;

  const EscalationSheet({
    super.key,
    required this.escalation,
    required this.queueIndex,
    required this.queueSize,
    required this.taskTitle,
    required this.channelName,
    required this.onReply,
    required this.onSkip,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final coral = tc.red;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: BoxDecoration(
        color: tc.sheet,
        border: Border(top: BorderSide(color: coral, width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: tc.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Header row: Tally avatar + "#channel · needs you" + queue badge + task line
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const TallyAvatar(size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '#$channelName',
                          style: TextStyle(
                            color: tc.fg,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          ' · ',
                          style: TextStyle(color: tc.fgXdim, fontSize: 13),
                        ),
                        Text(
                          'needs you',
                          style: TextStyle(
                            color: coral,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'about: $taskTitle',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tc.fgDim, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              if (queueSize > 1) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(color: coral, width: 1),
                  ),
                  child: Text(
                    '${queueIndex + 1} of $queueSize',
                    style: TextStyle(
                      color: coral,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          // Question
          Text(
            escalation.question,
            style: TextStyle(color: tc.fg, fontSize: 13.5, height: 1.4),
          ),
          const SizedBox(height: 14),
          // Quick reply buttons (one per option). 1-2 inline, 3+ stacked.
          if (escalation.options.length <= 2)
            Row(
              children: [
                for (int i = 0; i < escalation.options.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: i == 0
                        ? BrutalButton.primary(
                            label: escalation.options[i],
                            onPressed: () => onReply(escalation.options[i]),
                          )
                        : BrutalButton.outline(
                            label: escalation.options[i],
                            onPressed: () => onReply(escalation.options[i]),
                          ),
                  ),
                ],
              ],
            )
          else
            Column(
              children: [
                for (int i = 0; i < escalation.options.length; i++) ...[
                  if (i > 0) const SizedBox(height: 6),
                  i == 0
                      ? BrutalButton.primary(
                          label: escalation.options[i],
                          onPressed: () => onReply(escalation.options[i]),
                        )
                      : BrutalButton.outline(
                          label: escalation.options[i],
                          onPressed: () => onReply(escalation.options[i]),
                        ),
                ],
              ],
            ),
          const SizedBox(height: 10),
          // Bottom row: Open #channel ghost + Skip ghost
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: onOpen,
                style: TextButton.styleFrom(
                  foregroundColor: tc.fgXdim,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                  ),
                ),
                child: Text(
                  'OPEN #${channelName.toUpperCase()}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              if (queueSize > 1)
                TextButton(
                  onPressed: onSkip,
                  style: TextButton.styleFrom(
                    foregroundColor: tc.fgXdim,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                  child: const Text(
                    'SKIP',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
