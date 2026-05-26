import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';

/// Inline escalation card for embedding in long-term channel message streams
/// (Screen 5 pattern).
///
/// Renders a coral-bordered container with TallyAvatar, "TALLY NEEDS YOU"
/// header, the task title (italic dim), the escalation question, stacked quick
/// reply buttons, and an "OPEN TASK CHANNEL" ghost link at the bottom.
///
/// Example:
/// ```dart
/// InlineEscalationCard(
///   escalation: esc,
///   taskTitle: 'Fix daily-deals',
///   onReply: (option) async { /* post reply */ },
///   onOpenTask: () { /* navigate to task channel */ },
/// )
/// ```
class InlineEscalationCard extends StatelessWidget {
  final EscalationModel escalation;
  final String taskTitle;

  /// Called with the selected option string when the user taps a quick reply.
  final void Function(String option) onReply;

  /// Called when the user taps "OPEN TASK CHANNEL".
  final VoidCallback onOpenTask;

  const InlineEscalationCard({
    super.key,
    required this.escalation,
    required this.taskTitle,
    required this.onReply,
    required this.onOpenTask,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final coral = tc.red;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        // Amber wash — 6% opacity of coral to signal urgency without takeover
        color: tc.red.withValues(alpha: 0.06),
        border: Border.all(color: coral, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header row: Tally avatar + "TALLY NEEDS YOU" + task title (italic dim)
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
                    Text(
                      'TALLY NEEDS YOU',
                      style: TextStyle(
                        color: coral,
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      taskTitle,
                      style: TextStyle(
                        color: tc.fgDim,
                        fontFamily: 'JetBrainsMono',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Question
          Text(
            escalation.question,
            style: TextStyle(
              color: tc.fg,
              fontFamily: 'JetBrainsMono',
              fontSize: 13.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          // Quick reply buttons — 2 options inline (Row), 3+ stacked (Column).
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
          // Ghost link: "OPEN TASK CHANNEL" — navigates to the task channel
          // without dismissing the current long-term channel.
          // 12px arrow icon prefix per mockup (Screen 5 / Open button pattern).
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onOpenTask,
              style: TextButton.styleFrom(
                foregroundColor: tc.fgXdim,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero,
                ),
              ),
              icon: const Icon(Icons.arrow_forward, size: 12),
              label: const Text(
                'OPEN TASK CHANNEL',
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
