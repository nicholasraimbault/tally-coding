// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:tally_coding_app/theme/theme_builder.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';
import 'package:tally_coding_app/widgets/brutal/agent_avatar.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_cards.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog['tokyo-night']!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: tokens.bg,
      body: Center(
        child: SizedBox(
          width: 220,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    ),
  );
}

// ─── TodoCard previews ───────────────────────────────────────────────────────

@Preview(name: 'TodoCard — basic', group: 'KanbanCards')
Widget todoCardBasic() => _wrap(
      TodoCard(
        title: 'Fix daily-deals hero image on mobile',
        onTap: () => print('tap'),
      ),
    );

@Preview(name: 'TodoCard — queued badge', group: 'KanbanCards')
Widget todoCardQueued() => _wrap(
      TodoCard(
        title: 'Refactor auth token refresh',
        queued: true,
        onTap: () => print('tap'),
      ),
    );

// ─── PlanningCard previews ───────────────────────────────────────────────────

@Preview(name: 'PlanningCard', group: 'KanbanCards')
Widget planningCard() => _wrap(
      PlanningCard(
        title: 'Add Stripe billing integration',
        onTap: () => print('tap'),
      ),
    );

// ─── RunningTaskCard previews ────────────────────────────────────────────────

@Preview(name: 'RunningTaskCard — running', group: 'KanbanCards')
Widget runningTaskCardRunning() => _wrap(
      RunningTaskCard(
        title: 'Widget preview setup (B1)',
        agents: const [AgentRole.coder, AgentRole.tester],
        progress: 0.72,
        eta: '~4 min',
        onTap: () => print('tap'),
      ),
    );

@Preview(name: 'RunningTaskCard — escalated', group: 'KanbanCards')
Widget runningTaskCardEscalated() => _wrap(
      RunningTaskCard(
        title: 'Fix auth after clerk upgrade',
        agents: const [AgentRole.coder, AgentRole.architect],
        progress: 0.35,
        escalated: true,
        onTap: () => print('tap'),
      ),
    );

@Preview(name: 'RunningTaskCard — no progress bar', group: 'KanbanCards')
Widget runningTaskCardNoBar() => _wrap(
      RunningTaskCard(
        title: 'Write API docs for /channels',
        agents: const [AgentRole.reader],
        onTap: () => print('tap'),
      ),
    );

// ─── AwaitingCard previews ───────────────────────────────────────────────────

@Preview(name: 'AwaitingCard', group: 'KanbanCards')
Widget awaitingCard() => _wrap(
      AwaitingCard(
        title: 'Deploy to staging',
        action: 'Approve deploy',
        onTap: () => print('tap'),
      ),
    );

// ─── DoneCard previews ───────────────────────────────────────────────────────

@Preview(name: 'DoneCard — shipped', group: 'KanbanCards')
Widget doneCardShipped() => _wrap(
      DoneCard(
        title: 'Theme picker (B1)',
        shippedAgo: '2h ago',
        onTap: () => print('tap'),
      ),
    );

@Preview(name: 'DoneCard — failed', group: 'KanbanCards')
Widget doneCardFailed() => _wrap(
      DoneCard(
        title: 'Clerk OAuth deep-link',
        shippedAgo: '1h ago',
        failed: true,
        onTap: () => print('tap'),
      ),
    );

// ─── Full column overview ────────────────────────────────────────────────────

@Preview(name: 'All card types — column overview', group: 'KanbanCards')
Widget allKanbanCards() {
  final tokens = themeCatalog['tokyo-night']!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: tokens.bg,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: 220,
          child: Column(
            children: [
              TodoCard(title: 'Backlog task', onTap: () {}),
              const SizedBox(height: 8),
              PlanningCard(title: 'Planning: Stripe billing', onTap: () {}),
              const SizedBox(height: 8),
              RunningTaskCard(
                title: 'Running: Widget previews',
                agents: const [AgentRole.coder],
                progress: 0.72,
                onTap: () {},
              ),
              const SizedBox(height: 8),
              RunningTaskCard(
                title: 'Escalated: Auth broke',
                agents: const [AgentRole.coder, AgentRole.architect],
                progress: 0.35,
                escalated: true,
                onTap: () {},
              ),
              const SizedBox(height: 8),
              AwaitingCard(title: 'Awaiting: Deploy approval', action: 'Approve', onTap: () {}),
              const SizedBox(height: 8),
              DoneCard(title: 'Done: Theme picker', shippedAgo: '2h ago', onTap: () {}),
              const SizedBox(height: 8),
              DoneCard(title: 'Failed: OAuth redirect', shippedAgo: '1h ago', failed: true, onTap: () {}),
            ],
          ),
        ),
      ),
    ),
  );
}
