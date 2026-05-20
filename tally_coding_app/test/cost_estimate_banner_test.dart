import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/cost_estimate_banner.dart';

void main() {
  testWidgets('shows estimate text', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: CostEstimateBanner(
      estimatedCredits: 25,
      availableCredits: 1000,
      perTaskCapCredits: 100,
    ))));
    expect(find.textContaining('Estimated cost: 25 credits'), findsOneWidget);
  });

  test('estimateCreditsClientSide for short string', () {
    final out = estimateCreditsClientSide('write hello world');
    expect(out, greaterThanOrEqualTo(0));
    expect(out, lessThan(10));
  });

  test('estimateCreditsClientSide scales with length', () {
    final small = estimateCreditsClientSide('x' * 100);
    final big = estimateCreditsClientSide('x' * 10000);
    expect(big, greaterThan(small));
  });
}
