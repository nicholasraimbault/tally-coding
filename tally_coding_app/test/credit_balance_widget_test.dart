import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/credit_balance_widget.dart';

void main() {
  testWidgets('renders plan label and credit count', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CreditBalanceWidget(
      planLabel: 'Pro (Beta)',
      isBeta: true,
      usedCredits: 250,
      includedCredits: 1000,
      prepaidCreditBalance: 0,
      periodStart: 0,
    ))));
    expect(find.text('Pro (Beta)'), findsOneWidget);
    expect(find.text('Beta — locked'), findsOneWidget);
    expect(find.text('250 / 1000 credits used'), findsOneWidget);
  });

  testWidgets('shows prepaid balance line', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CreditBalanceWidget(
      planLabel: 'Pro (Beta)',
      isBeta: true,
      usedCredits: 100,
      includedCredits: 1000,
      prepaidCreditBalance: 500,
      periodStart: 0,
    ))));
    expect(find.textContaining('Prepaid balance: 500'), findsOneWidget);
  });
}
