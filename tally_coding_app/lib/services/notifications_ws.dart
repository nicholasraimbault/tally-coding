// tally_coding_app/lib/services/notifications_ws.dart
//
// Sprint 46 B10: WebSocket client for /ws/notifications.
//
// Uses the doorbell pattern: a lightweight WS signal arrives containing
// only the notification ID; the content is then fetched over REST. This
// keeps the WS frame tiny and avoids re-implementing push-payload parsing
// in two places. Reconnects with exponential back-off (1 s → 60 s cap).
import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../api.dart';
import 'desktop_notifier.dart';

class NotificationsWsClient {
  final TallyOrchClient api;
  final Uri wsUrl;
  final Future<String?> Function() bearerProvider;
  WebSocketChannel? _channel;
  Timer? _reconnect;
  StreamSubscription? _sub;
  int _backoffSeconds = 1;

  /// Called for every fully-fetched notification payload (after the
  /// REST fetch completes). Callers can set this to update UI state.
  void Function(Map<String, dynamic>)? onNotification;

  /// Called when a `new_message` event arrives on the WS connection.
  /// Provides the [channelId] and [messageId] from the server frame so
  /// callers can fetch or refresh the relevant message without polling.
  void Function(int channelId, int messageId)? onNewMessage;

  NotificationsWsClient({
    required this.api,
    required this.wsUrl,
    required this.bearerProvider,
  });

  Future<void> connect() async {
    final token = await bearerProvider();
    if (token == null) {
      _scheduleReconnect();
      return;
    }
    final uri = wsUrl.replace(queryParameters: {'token': token});
    try {
      _channel = WebSocketChannel.connect(uri);
      _sub = _channel!.stream.listen(
        _handleMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
      );
      _backoffSeconds = 1; // reset on successful connect
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    _reconnect?.cancel();
    _reconnect = Timer(Duration(seconds: _backoffSeconds), () {
      _backoffSeconds = (_backoffSeconds * 2).clamp(1, 60);
      connect();
    });
  }

  Future<void> _handleMessage(dynamic raw) async {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final type = msg['type'] as String?;
    if (type == 'hello' || type == 'pong') return;
    if (type == 'new_message') {
      onNewMessage?.call(msg['channel_id'] as int, msg['message_id'] as int);
      return;
    }
    if (type == 'new_notification') {
      final id = msg['id'] as int;
      try {
        // Doorbell pattern: signal arrives via WS, fetch content via REST.
        final items = await api.listNotifications(limit: 1, sinceId: id - 1);
        for (final n in items) {
          if (n['id'] == id) {
            onNotification?.call(n);
            // Show OS-native notification on desktop platforms.
            await DesktopNotifier.instance.showNotification(
              id: id,
              title: n['kind'] as String,
              body: n['payload_json'] as String? ?? '',
            );
            break;
          }
        }
      } catch (_) {
        // Network blip; inbox tab will catch up on next refresh.
      }
    }
  }

  void dispose() {
    _reconnect?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
  }
}
