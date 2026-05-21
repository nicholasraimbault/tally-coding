import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/message_composer.dart';

void main() {
  testWidgets('sends text on enter + clears field', (tester) async {
    String? sent;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MessageComposer(onSend: (text) async => sent = text, placeholder: 'Type...'),
    )));
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(sent, 'hello');
    // Field should be cleared after send
    expect(find.text('hello'), findsNothing);
  });

  testWidgets('does not send empty text', (tester) async {
    int sendCount = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MessageComposer(onSend: (text) async { sendCount++; }, placeholder: ''),
    )));
    await tester.testTextInput.receiveAction(TextInputAction.send);
    expect(sendCount, 0);
  });

  testWidgets('send button triggers send', (tester) async {
    String? sent;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MessageComposer(onSend: (t) async => sent = t, placeholder: ''),
    )));
    await tester.enterText(find.byType(TextField), 'via button');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(sent, 'via button');
  });
}
