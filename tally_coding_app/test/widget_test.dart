import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/task_list.dart';

void main() {
  testWidgets('TaskListScreen renders with an empty client', (WidgetTester tester) async {
    final client = TallyOrchClient(baseUrl: Uri.parse('http://127.0.0.1:65535'), token: 'fake');
    await tester.pumpWidget(MaterialApp(home: TaskListScreen(client: client)));
    expect(find.text('Tally Coding'), findsOneWidget);
    expect(find.text('New task'), findsOneWidget);
  });
}
