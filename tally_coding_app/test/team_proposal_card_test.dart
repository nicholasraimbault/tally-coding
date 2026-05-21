import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/team_proposal_card.dart';

void main() {
  testWidgets('renders description, team summary, 3 buttons', (tester) async {
    final msg = {
      'id': 1, 'channel_id': 1, 'author_kind': 'tally',
      'kind': 'team_proposal',
      'payload_json': jsonEncode({
        'task_id': 'abc',
        'description': 'build a sorter',
        'team_spec': {
          'nodes': [
            {'id': 'n1', 'kind': 'agent', 'role': 'Coder'},
            {'id': 'n2', 'kind': 'agent', 'role': 'Tester'},
          ],
          'edges': [],
        },
        'options': [
          {'value': 'approve', 'label': 'Approve & dispatch'},
          {'value': 'edit', 'label': 'Edit in builder'},
          {'value': 'cancel', 'label': 'Cancel'},
        ],
      }),
      'created_at': 1700000000.0,
    };
    String? clicked;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      TeamProposalCard(message: msg, onAction: (v) => clicked = v),
    )));
    expect(find.textContaining('build a sorter'), findsOneWidget);
    expect(find.textContaining('Coder'), findsOneWidget);
    expect(find.textContaining('Tester'), findsOneWidget);
    expect(find.text('Approve & dispatch'), findsOneWidget);
    expect(find.text('Edit in builder'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Approve & dispatch'));
    await tester.pumpAndSettle();
    expect(clicked, 'approve');
  });

  testWidgets('greys buttons when cancelled', (tester) async {
    final msg = {
      'id': 1, 'channel_id': 1, 'author_kind': 'tally',
      'kind': 'team_proposal',
      'payload_json': jsonEncode({
        'task_id': 'abc', 'description': 'x',
        'team_spec': {'nodes': [], 'edges': []},
        'options': [{'value':'approve','label':'Approve'}],
        'cancelled': true,
      }),
      'created_at': 1700000000.0,
    };
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      TeamProposalCard(message: msg, onAction: (v) {}),
    )));
    expect(find.textContaining('cancelled'), findsOneWidget);
  });
}
