import 'package:flutter_test/flutter_test.dart';

import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/main.dart';

void main() {
  testWidgets('App boots without crash', (WidgetTester tester) async {
    final client = TallyOrchClient(baseUrl: Uri.parse('http://127.0.0.1:65535'));
    await tester.pumpWidget(TallyCodingApp(client: client));
    // The list screen should be visible
    expect(find.text('Tally Coding'), findsOneWidget);
    expect(find.text('New task'), findsOneWidget);
  });
}
