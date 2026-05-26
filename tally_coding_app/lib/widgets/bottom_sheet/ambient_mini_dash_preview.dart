import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:tally_coding_app/theme/theme_builder.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';
import 'package:tally_coding_app/widgets/brutal/agent_avatar.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/ambient_mini_dash.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog['tokyo-night']!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: tokens.bg,
      body: Align(
        alignment: Alignment.bottomCenter,
        child: child,
      ),
    ),
  );
}

// ─── AmbientMiniDash previews ────────────────────────────────────────────────

@Preview(name: 'Empty state (0 open, 0 done)', group: 'AmbientMiniDash')
Widget ambientMiniDashEmpty() => _wrap(
      const AmbientMiniDash(
        openCount: 0,
        doneCount: 0,
        taskRows: [],
        narratorText: null,
      ),
    );

@Preview(name: 'With task rows', group: 'AmbientMiniDash')
Widget ambientMiniDashWithRows() => _wrap(
      AmbientMiniDash(
        openCount: 3,
        doneCount: 5,
        taskRows: [
          const MiniTaskRow(
            title: 'Fix daily-deals hero image',
            progress: 0.72,
            agents: [AgentRole.coder, AgentRole.tester],
          ),
          const MiniTaskRow(
            title: 'Add auth token refresh',
            progress: 0.35,
            agents: [AgentRole.architect],
          ),
          const MiniTaskRow(
            title: 'Widget preview setup',
            progress: 1.0,
            agents: [AgentRole.coder],
          ),
        ],
        narratorText: null,
      ),
    );

@Preview(name: 'With narrator bubble', group: 'AmbientMiniDash')
Widget ambientMiniDashWithNarrator() => _wrap(
      AmbientMiniDash(
        openCount: 2,
        doneCount: 1,
        taskRows: [
          const MiniTaskRow(
            title: 'Refactor kanban column',
            progress: 0.55,
            agents: [AgentRole.coder, AgentRole.reader],
          ),
        ],
        narratorText: 'Working on the kanban column refactor. Reviewing PRs from the coder agent now — should have a diff ready in ~4 min.',
      ),
    );

@Preview(name: 'Empty state with narrator', group: 'AmbientMiniDash')
Widget ambientMiniDashEmptyNarrator() => _wrap(
      const AmbientMiniDash(
        openCount: 0,
        doneCount: 12,
        taskRows: [],
        narratorText: 'All queued tasks complete. Ready for your next request.',
      ),
    );
