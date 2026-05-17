import 'package:flutter/material.dart';

import 'api.dart';
import 'screens/task_list.dart';

void main() {
  final orchUrl = const String.fromEnvironment(
    'TALLY_ORCH_URL',
    defaultValue: 'http://127.0.0.1:8080',
  );
  final client = TallyOrchClient(baseUrl: Uri.parse(orchUrl));
  runApp(TallyCodingApp(client: client));
}

class TallyCodingApp extends StatelessWidget {
  final TallyOrchClient client;
  const TallyCodingApp({super.key, required this.client});

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
        home: TaskListScreen(client: client),
      );
}
