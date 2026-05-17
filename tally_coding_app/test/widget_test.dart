import 'package:flutter_test/flutter_test.dart';

import 'package:tally_coding_app/main.dart';

void main() {
  testWidgets('Placeholder shows stack tagline', (WidgetTester tester) async {
    await tester.pumpWidget(const TallyCodingApp());
    expect(find.text('Tally Coding'), findsOneWidget);
    expect(find.textContaining('Privacy-first'), findsOneWidget);
    expect(find.textContaining('OpenHands'), findsOneWidget);
  });
}
