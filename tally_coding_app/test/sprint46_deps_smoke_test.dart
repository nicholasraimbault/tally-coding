import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:unifiedpush/unifiedpush.dart';

void main() {
  test('sprint 46 packages import cleanly', () {
    expect(WebSocketChannel, isNotNull);
    expect(FlutterLocalNotificationsPlugin, isNotNull);
    expect(UnifiedPush, isNotNull);
  });
}
