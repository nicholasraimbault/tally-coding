import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';

/// Card for tasks queued but not yet picked up by the architect.
class TodoCard extends StatelessWidget {
  final String title;
  final bool queued;
  final VoidCallback? onTap;

  const TodoCard({
    super.key,
    required this.title,
    this.queued = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return BrutalCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tc.fg,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          if (queued) ...[
            const SizedBox(height: 8),
            Text(
              'QUEUED',
              style: TextStyle(
                color: tc.fgXdim,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Card for tasks the architect is breaking down (pending + teamSpec != null).
class PlanningCard extends StatelessWidget {
  final String title;
  final VoidCallback? onTap;

  const PlanningCard({
    super.key,
    required this.title,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return BrutalCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tc.fg,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const AgentAvatar(role: AgentRole.architect, size: 20),
              Text(
                'PLANNING',
                style: TextStyle(
                  color: tc.fgXdim,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Card for tasks workers are actively executing.
/// Shows agent avatars + ETA + progress bar (optional — null hides bar).
/// When [escalated] is true: coral border + coral wash bg + "PAUSED · NEEDS YOU"
/// footer, signaling that this task is awaiting operator input via bottom sheet.
class RunningTaskCard extends StatelessWidget {
  final String title;
  final List<AgentRole> agents;

  /// Progress value 0.0–1.0. Null means progress is unknown — bar is hidden.
  final double? progress;
  final String? eta;
  final bool escalated;
  final VoidCallback? onTap;

  const RunningTaskCard({
    super.key,
    required this.title,
    required this.agents,
    this.progress,
    this.eta,
    this.escalated = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final coral = tc.red;
    // When escalated: coral wash bg + coral border override the normal card chrome.
    final decoration = escalated
        ? BoxDecoration(
            color: Color.alphaBlend(coral.withValues(alpha: 0.05), tc.card),
            border: Border.all(color: coral.withValues(alpha: 0.45), width: 1),
            borderRadius: BorderRadius.zero,
          )
        : null;
    Widget card = Container(
      padding: const EdgeInsets.all(13),
      decoration: decoration ??
          BoxDecoration(
            color: tc.card,
            border: Border.all(color: tc.border, width: 1),
            borderRadius: BorderRadius.zero,
          ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tc.fg,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: 4,
                children: [
                  for (final role in agents) AgentAvatar(role: role, size: 20),
                ],
              ),
              if (eta != null)
                Text(
                  eta!,
                  style: TextStyle(
                    color: tc.fgDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            BrutalProgressBar(value: progress!),
          ],
          if (escalated) ...[
            const SizedBox(height: 8),
            Text(
              'PAUSED · NEEDS YOU',
              style: TextStyle(
                color: coral,
                fontFamily: 'JetBrainsMono',
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap != null) {
      card = GestureDetector(onTap: onTap, child: card);
    }
    return card;
  }
}

/// Card for tasks waiting on user input (paused agents).
/// Amber-tinted via tc.red token + action pill.
class AwaitingCard extends StatelessWidget {
  final String title;
  final String action;
  final VoidCallback? onTap;

  const AwaitingCard({
    super.key,
    required this.title,
    required this.action,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return BrutalCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tc.fg,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          BrutalPill(label: action), // default red accent (escalation/needs-you color)
        ],
      ),
    );
  }
}

/// Card for completed tasks (or failed — distinguishes via the failed flag).
class DoneCard extends StatelessWidget {
  final String title;
  final String shippedAgo;
  final bool failed;
  final VoidCallback? onTap;

  const DoneCard({
    super.key,
    required this.title,
    required this.shippedAgo,
    this.failed = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final accentColor = failed ? tc.red : tc.green;
    final label = failed ? 'FAILED' : 'SHIPPED';
    return BrutalCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tc.fgDim, // dim — done is less salient than active work
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: accentColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              Text(
                shippedAgo,
                style: TextStyle(
                  color: tc.fgXdim,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Inline ghost row at the bottom of every kanban column.
/// Notion mobile pattern: transparent bg, square corners, "+ New task" label.
class NewTaskRow extends StatefulWidget {
  final VoidCallback onTap;

  const NewTaskRow({super.key, required this.onTap});

  @override
  State<NewTaskRow> createState() => _NewTaskRowState();
}

class _NewTaskRowState extends State<NewTaskRow> {
  bool _hov = false;

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return MouseRegion(
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          color: _hov ? tc.card : Colors.transparent,
          child: Text(
            '+ New task',
            style: TextStyle(
              color: _hov ? tc.fgDim : tc.fgXdim,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }
}
