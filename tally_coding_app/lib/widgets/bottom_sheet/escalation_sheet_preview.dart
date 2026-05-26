// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:tally_coding_app/theme/theme_builder.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_sheet.dart';

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

// ─── EscalationSheet fixtures ────────────────────────────────────────────────

const _esc2Options = EscalationModel(
  id: 'esc-1',
  question: 'The daily-deals hero image is missing on mobile. Should I add a placeholder or wait for the asset?',
  options: ['Add placeholder', 'Wait for asset'],
  taskId: 'task-42',
  channelId: 1,
);

const _esc4Options = EscalationModel(
  id: 'esc-2',
  question: 'Auth flow broke after clerk upgrade. Which recovery path should I take?',
  options: ['Revert clerk', 'Patch token refresh', 'Open issue + skip', 'Escalate to Nick'],
  taskId: 'task-77',
  channelId: 2,
);

const _escSingle = EscalationModel(
  id: 'esc-3',
  question: 'Payment webhook is returning 500 on the staging server. Should I disable it temporarily?',
  options: ['Disable temporarily'],
  taskId: 'task-99',
  channelId: 3,
);

// ─── Previews ────────────────────────────────────────────────────────────────

@Preview(name: '2-option (inline row)', group: 'EscalationSheet')
Widget escalationSheet2Options() => _wrap(
      EscalationSheet(
        escalation: _esc2Options,
        queueIndex: 0,
        queueSize: 1,
        taskTitle: 'Fix daily-deals hero image',
        channelName: 'daily-deals',
        onReply: (opt) => print('reply: $opt'),
        onSkip: () => print('skip'),
        onOpen: () => print('open'),
      ),
    );

@Preview(name: '4-option (stacked)', group: 'EscalationSheet')
Widget escalationSheet4Options() => _wrap(
      EscalationSheet(
        escalation: _esc4Options,
        queueIndex: 0,
        queueSize: 1,
        taskTitle: 'Fix auth flow after clerk upgrade',
        channelName: 'auth',
        onReply: (opt) => print('reply: $opt'),
        onSkip: () => print('skip'),
        onOpen: () => print('open'),
      ),
    );

@Preview(name: '1 of 5 queue badge', group: 'EscalationSheet')
Widget escalationSheet1of5() => _wrap(
      EscalationSheet(
        escalation: _esc2Options,
        queueIndex: 0,
        queueSize: 5,
        taskTitle: 'Fix daily-deals hero image',
        channelName: 'daily-deals',
        onReply: (opt) => print('reply: $opt'),
        onSkip: () => print('skip'),
        onOpen: () => print('open'),
      ),
    );

@Preview(name: 'Single option', group: 'EscalationSheet')
Widget escalationSheetSingle() => _wrap(
      EscalationSheet(
        escalation: _escSingle,
        queueIndex: 0,
        queueSize: 1,
        taskTitle: 'Payment webhook 500',
        channelName: 'payments',
        onReply: (opt) => print('reply: $opt'),
        onSkip: () => print('skip'),
        onOpen: () => print('open'),
      ),
    );
