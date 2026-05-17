import 'package:flutter/material.dart';

import 'api.dart';
import 'screens/task_detail.dart';
import 'screens/task_list.dart';

void main() {
  final orchUrl = const String.fromEnvironment(
    'TALLY_ORCH_URL',
    defaultValue: 'http://127.0.0.1:8080',
  );
  // Optional: open a specific task on startup (used for screenshots / deep links).
  final openTaskId = const String.fromEnvironment('TALLY_OPEN_TASK_ID');
  final client = TallyOrchClient(baseUrl: Uri.parse(orchUrl));
  runApp(TallyCodingApp(client: client, openTaskId: openTaskId.isEmpty ? null : openTaskId));
}

class TallyCodingApp extends StatelessWidget {
  final TallyOrchClient client;
  final String? openTaskId;
  const TallyCodingApp({super.key, required this.client, this.openTaskId});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tally Coding',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF7C5CFC),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: openTaskId != null
            ? TaskDetailScreen(client: client, taskId: openTaskId!)
            : TaskListScreen(client: client),
      );
}
