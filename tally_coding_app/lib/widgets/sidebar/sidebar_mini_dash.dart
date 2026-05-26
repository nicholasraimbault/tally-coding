import 'package:flutter/material.dart';
import '../../theme/tc_tokens.dart';
import '../../widgets/brutal/tally_avatar.dart';
import '../../widgets/brutal/agent_avatar.dart';
import '../../widgets/brutal/brutal_progress_bar.dart';

/// Data for a single running task shown in the sidebar mini-dash.
@immutable
class SidebarMiniTaskData {
  final String title;
  final List<String> agentRoles; // e.g. ['architect', 'coder']
  final int progressPct; // 0–100
  const SidebarMiniTaskData({
    required this.title,
    required this.agentRoles,
    required this.progressPct,
  });
}

/// Data for a single escalation item shown in the sidebar takeover.
///
/// Mirrors B3's EscalationModel shape; defined here so B5 compiles
/// independently of the bottom-sheet B3 types.
@immutable
class SidebarEscalationData {
  final String channelName;
  final String taskName;
  final String question;
  final List<String> quickReplies; // first = primary; rest = outline
  final List<String> emphasizedTerms; // bold in TC.fg weight-700
  const SidebarEscalationData({
    required this.channelName,
    required this.taskName,
    required this.question,
    required this.quickReplies,
    required this.emphasizedTerms,
  });
}

/// Desktop variant of the mini-dash, docked at the bottom of the sidebar.
///
/// Two states:
/// - **Ambient** (escalations is empty): stat row + per-task rows + narrator bubble.
/// - **Takeover** (escalations is non-empty): coral wash + question + stacked buttons.
///
/// No drag handle — this is a static docked footer, not a draggable sheet.
///
/// Content area is 212 px wide (240 sidebar − 14 px padding × 2).
///
/// Example (ambient):
/// ```dart
/// SidebarMiniDash(
///   openCount: 6,
///   doneToday: 3,
///   tasks: [...],
///   narratorText: 'Coder is patching — PR in ~5 min.',
///   narratorEmphasis: ['Coder is patching'],
///   escalations: const [],
///   onQuickReply: (_) {},
///   onSkipEscalation: () {},
///   onOpenChannel: () {},
/// )
/// ```
class SidebarMiniDash extends StatelessWidget {
  // Ambient state
  final int openCount;
  final int doneToday;
  final List<SidebarMiniTaskData> tasks;
  final String narratorText;
  final List<String> narratorEmphasis;
  // Escalation state
  final List<SidebarEscalationData> escalations;
  final void Function(String reply) onQuickReply;
  final VoidCallback onSkipEscalation;
  final VoidCallback onOpenChannel;
  // Index into escalations currently shown (0-based)
  final int activeEscalationIndex;

  const SidebarMiniDash({
    super.key,
    required this.openCount,
    required this.doneToday,
    required this.tasks,
    required this.narratorText,
    required this.narratorEmphasis,
    required this.escalations,
    required this.onQuickReply,
    required this.onSkipEscalation,
    required this.onOpenChannel,
    this.activeEscalationIndex = 0,
  });

  bool get _isEscalation => escalations.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return _isEscalation
        ? _buildEscalation(context, tc)
        : _buildAmbient(context, tc);
  }

  Widget _buildAmbient(BuildContext context, TCTokens tc) {
    return Container(
      decoration: BoxDecoration(
        color: tc.sheet,
        border: Border(top: BorderSide(color: tc.border, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stat row: "6 open | 3 done today"
          _StatRow(openCount: openCount, doneToday: doneToday, tc: tc),
          if (tasks.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(height: 1, color: tc.border),
            const SizedBox(height: 2),
            for (int i = 0; i < tasks.length; i++) ...[
              _TaskRow(data: tasks[i], tc: tc),
              if (i < tasks.length - 1) Container(height: 1, color: tc.border),
            ],
          ],
          const SizedBox(height: 8),
          _NarratorBubbleInline(
            text: narratorText,
            emphasis: narratorEmphasis,
            tc: tc,
          ),
        ],
      ),
    );
  }

  Widget _buildEscalation(BuildContext context, TCTokens tc) {
    final safeIndex =
        activeEscalationIndex.clamp(0, escalations.length - 1);
    final item = escalations[safeIndex];
    final total = escalations.length;
    final isMulti = total > 1;

    return Stack(
      children: [
        // Base container with coral top border + sheet bg
        Container(
          decoration: BoxDecoration(
            color: tc.sheet,
            border: Border(
              top: BorderSide(
                // coral at 45% opacity: rgba(247,118,142,0.45)
                color: const Color(0x73F7768E),
                width: 1,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: TallyAvatar + channel context + 1/N pill
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const TallyAvatar(size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // "#general · needs you"
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                '＃${item.channelName}',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: tc.fg,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  fontFamily: 'JetBrainsMono',
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text('│',
                                style: TextStyle(
                                    color: tc.fgDimmer, fontSize: 10)),
                            const SizedBox(width: 4),
                            Text(
                              'needs you',
                              style: TextStyle(
                                color: tc.red,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                                fontFamily: 'JetBrainsMono',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        // "about: <task name>"
                        Text(
                          'about: ${item.taskName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tc.fgXdim,
                            fontSize: 10.5,
                            fontFamily: 'JetBrainsMono',
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isMulti) ...[
                    const SizedBox(width: 6),
                    // "1/N" pill: 1px coral border, no fill, coral text
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: tc.red, width: 1),
                      ),
                      child: Text(
                        '${safeIndex + 1}/$total',
                        style: TextStyle(
                          color: tc.red,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                          fontFamily: 'JetBrainsMono',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              // Question text with emphasized terms
              _buildQuestionText(context, tc, item),
              const SizedBox(height: 12),
              // Quick replies — stacked vertically (sidebar is too narrow for inline)
              _buildQuickReplies(tc, item),
              const SizedBox(height: 8),
              // Bottom row: "Open #channel" ghost + "Skip →" ghost
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: _GhostButton(
                      label: '💬 Open #${item.channelName}',
                      onTap: onOpenChannel,
                      tc: tc,
                    ),
                  ),
                  _GhostButton(
                    key: const Key('sidebar_escalation_skip'),
                    label: 'Skip →',
                    onTap: onSkipEscalation,
                    tc: tc,
                  ),
                ],
              ),
            ],
          ),
        ),
        // Coral wash overlay
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              // rgba(247,118,142,0.06) ≈ 0x0F
              color: const Color(0x0FF7768E),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildQuestionText(
      BuildContext context, TCTokens tc, SidebarEscalationData item) {
    if (item.emphasizedTerms.isEmpty) {
      return Text(
        item.question,
        style: TextStyle(
          color: tc.fgDim,
          fontSize: 12,
          height: 1.45,
          fontFamily: 'JetBrainsMono',
        ),
      );
    }
    final spans = <TextSpan>[];
    var remaining = item.question;
    for (final term in item.emphasizedTerms) {
      final idx = remaining.indexOf(term);
      if (idx == -1) continue;
      if (idx > 0) {
        spans.add(TextSpan(
          text: remaining.substring(0, idx),
          style: TextStyle(color: tc.fgDim, fontSize: 12, height: 1.45),
        ));
      }
      spans.add(TextSpan(
        text: term,
        style: TextStyle(
          color: tc.fg,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          height: 1.45,
        ),
      ));
      remaining = remaining.substring(idx + term.length);
    }
    if (remaining.isNotEmpty) {
      spans.add(TextSpan(
        text: remaining,
        style: TextStyle(color: tc.fgDim, fontSize: 12, height: 1.45),
      ));
    }
    return RichText(
      text: TextSpan(
        style: const TextStyle(fontFamily: 'JetBrainsMono'),
        children: spans,
      ),
    );
  }

  Widget _buildQuickReplies(TCTokens tc, SidebarEscalationData item) {
    if (item.quickReplies.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (int i = 0; i < item.quickReplies.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            height: 34,
            child: i == 0
                ? _PrimaryButton(
                    label: item.quickReplies[i],
                    onTap: () => onQuickReply(item.quickReplies[i]),
                    tc: tc,
                  )
                : _OutlineButton(
                    label: item.quickReplies[i],
                    onTap: () => onQuickReply(item.quickReplies[i]),
                    tc: tc,
                  ),
          ),
        ],
      ],
    );
  }
}

// ─── Ambient sub-widgets ──────────────────────────────────────────────────

class _StatRow extends StatelessWidget {
  final int openCount;
  final int doneToday;
  final TCTokens tc;
  const _StatRow(
      {required this.openCount, required this.doneToday, required this.tc});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '$openCount',
          style: TextStyle(
            color: tc.fg,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontFamily: 'JetBrainsMono',
            height: 1,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          'OPEN',
          style: TextStyle(
            color: tc.fgXdim,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            fontFamily: 'JetBrainsMono',
          ),
        ),
        const SizedBox(width: 4),
        Text(
          '│',
          style: TextStyle(color: tc.fgDimmer, fontSize: 11),
        ),
        const SizedBox(width: 4),
        Text(
          '$doneToday',
          style: TextStyle(
            color: tc.fg,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontFamily: 'JetBrainsMono',
            height: 1,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          'DONE TODAY',
          style: TextStyle(
            color: tc.fgXdim,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            fontFamily: 'JetBrainsMono',
          ),
        ),
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  final SidebarMiniTaskData data;
  final TCTokens tc;
  const _TaskRow({required this.data, required this.tc});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          // Agent micro-avatars (16 px) — resolve role string to AgentRole
          for (int i = 0; i < data.agentRoles.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            AgentAvatar(
              role: _resolveRole(data.agentRoles[i]),
              size: 16,
              active: i == 0,
            ),
          ],
          const SizedBox(width: 7),
          // Task title (truncated)
          Expanded(
            child: Text(
              data.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tc.fgDim,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Progress bar (42 px wide, 3 px tall)
          SizedBox(
            width: 42,
            child: BrutalProgressBar(value: data.progressPct / 100.0, height: 3),
          ),
          const SizedBox(width: 4),
          // Progress percentage
          SizedBox(
            width: 24,
            child: Text(
              '${data.progressPct}%',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: tc.fgXdim,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Resolve a role string like 'architect' or 'coder' to the [AgentRole] enum.
  /// Case-insensitive; falls back to [AgentRole.coder] for unknown strings.
  static AgentRole _resolveRole(String roleStr) {
    final lower = roleStr.toLowerCase();
    for (final value in AgentRole.values) {
      if (value.name.toLowerCase() == lower) return value;
    }
    return AgentRole.coder;
  }
}

class _NarratorBubbleInline extends StatelessWidget {
  final String text;
  final List<String> emphasis;
  final TCTokens tc;
  const _NarratorBubbleInline(
      {required this.text, required this.emphasis, required this.tc});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const TallyAvatar(size: 22),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: tc.border, width: 1),
              color: Colors.transparent,
            ),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
            child: _buildRichText(context),
          ),
        ),
      ],
    );
  }

  Widget _buildRichText(BuildContext context) {
    final tc = context.tc;
    if (emphasis.isEmpty) {
      return Text(
        text,
        style: TextStyle(
          color: tc.fgDim,
          fontSize: 11.5,
          height: 1.45,
          fontFamily: 'JetBrainsMono',
        ),
      );
    }
    // Split text at emphasis spans and build RichText
    final spans = <TextSpan>[];
    var remaining = text;
    for (final phrase in emphasis) {
      final idx = remaining.indexOf(phrase);
      if (idx == -1) continue;
      if (idx > 0) {
        spans.add(TextSpan(
          text: remaining.substring(0, idx),
          style: TextStyle(color: tc.fgDim, fontSize: 11.5, height: 1.45),
        ));
      }
      spans.add(TextSpan(
        text: phrase,
        style: TextStyle(
          color: tc.fg,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          height: 1.45,
        ),
      ));
      remaining = remaining.substring(idx + phrase.length);
    }
    if (remaining.isNotEmpty) {
      spans.add(TextSpan(
        text: remaining,
        style: TextStyle(color: tc.fgDim, fontSize: 11.5, height: 1.45),
      ));
    }
    return RichText(
      text: TextSpan(
        style: const TextStyle(fontFamily: 'JetBrainsMono'),
        children: spans,
      ),
    );
  }
}

// ─── Escalation sub-widgets ────────────────────────────────────────────────

class _PrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final TCTokens tc;
  const _PrimaryButton(
      {required this.label, required this.onTap, required this.tc});

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _hov = false;
  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          color: _hov
              ? Color.fromRGBO(
                  tc.green.r.toInt(), tc.green.g.toInt(), tc.green.b.toInt(), 0.85)
              : tc.green,
          alignment: Alignment.center,
          child: Text(
            widget.label.toUpperCase(),
            style: TextStyle(
              color: tc.bg,
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
              letterSpacing: 0.8,
              fontFamily: 'JetBrainsMono',
            ),
          ),
        ),
      ),
    );
  }
}

class _OutlineButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final TCTokens tc;
  const _OutlineButton(
      {required this.label, required this.onTap, required this.tc});

  @override
  State<_OutlineButton> createState() => _OutlineButtonState();
}

class _OutlineButtonState extends State<_OutlineButton> {
  bool _hov = false;
  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: _hov
                ? Color.fromRGBO(
                    tc.fg.r.toInt(), tc.fg.g.toInt(), tc.fg.b.toInt(), 0.05)
                : Colors.transparent,
            border: Border.all(
              color: _hov ? tc.borderStr : tc.border,
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label.toUpperCase(),
            style: TextStyle(
              color: tc.fg,
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
              letterSpacing: 0.8,
              fontFamily: 'JetBrainsMono',
            ),
          ),
        ),
      ),
    );
  }
}

class _GhostButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final TCTokens tc;
  const _GhostButton(
      {super.key, required this.label, required this.onTap, required this.tc});

  @override
  State<_GhostButton> createState() => _GhostButtonState();
}

class _GhostButtonState extends State<_GhostButton> {
  bool _hov = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            widget.label,
            style: TextStyle(
              color: _hov ? widget.tc.fg : widget.tc.fgXdim,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: 0.6,
              fontFamily: 'JetBrainsMono',
            ),
          ),
        ),
      ),
    );
  }
}
