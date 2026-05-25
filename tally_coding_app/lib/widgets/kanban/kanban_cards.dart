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
