// tally_coding_app/lib/services/escalation_notifier.dart
//
// B4: EscalationNotifier — parses escalation push payloads and dispatches
// OS notifications with inline action buttons.
//
// Push body from orchestrator (JSON):
//   {
//     "type": "escalation",
//     "escalation_message_id": int,
//     "channel_id": int,
//     "question": str,
//     "quick_reply_options": ["Option A", ..., "Open"],
//   }
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Parsed representation of an escalation push payload.
class EscalationPushPayload {
  final int escalationMessageId;
  final int channelId;
  final String question;
  final List<String> quickReplyOptions;

  const EscalationPushPayload({
    required this.escalationMessageId,
    required this.channelId,
    required this.question,
    required this.quickReplyOptions,
  });

  /// Parse from raw bytes received on the UnifiedPush endpoint.
  /// Returns null if bytes are not a valid escalation payload.
  static EscalationPushPayload? fromBytes(List<int> bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (json['type'] != 'escalation') return null;
      return EscalationPushPayload(
        escalationMessageId: json['escalation_message_id'] as int,
        channelId: json['channel_id'] as int,
        question: (json['question'] as String?) ?? '',
        quickReplyOptions: List<String>.from(
          (json['quick_reply_options'] as List?) ?? const [],
        ),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Manages OS escalation push notifications with inline action buttons.
///
/// On Android: uses `flutter_local_notifications` with `NotificationAction`
/// for each quick reply option.
/// On iOS: shows a notification in the `tally_escalation` category whose
/// actions are configured in AppDelegate (see Task 11 / B4).
/// On Linux/desktop: falls back to a plain notification with no actions.
class EscalationNotifier {
  EscalationNotifier._();
  static final EscalationNotifier instance = EscalationNotifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Called when the user taps a quick-reply action button in the OS notification.
  /// Provides the [channelId], [escalationMessageId], and the chosen [actionId]
  /// (which is the option string, e.g. "2 decimals").
  void Function(int channelId, int escalationMessageId, String actionId)?
      onActionSelected;

  /// Initialize the notification plugin.
  /// Must be called before [showEscalationNotification].
  ///
  /// Example:
  /// ```dart
  /// await EscalationNotifier.instance.initialize();
  /// ```
  Future<void> initialize() async {
    if (_initialized) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: false,
    );
    const linuxInit = LinuxInitializationSettings(
      defaultActionName: 'Open',
    );

    await _plugin.initialize(
      const InitializationSettings(
        android: androidInit,
        iOS: darwinInit,
        macOS: darwinInit,
        linux: linuxInit,
      ),
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );
    _initialized = true;
  }

  void _onNotificationResponse(NotificationResponse response) {
    // Action payload encodes "channelId:escalationMessageId:actionLabel"
    final actionPayload = response.payload ?? '';
    final parts = actionPayload.split(':');
    if (parts.length < 3) return;
    final channelId = int.tryParse(parts[0]);
    final msgId = int.tryParse(parts[1]);
    if (channelId == null || msgId == null) return;
    final actionId = response.actionId ?? parts.sublist(2).join(':');
    onActionSelected?.call(channelId, msgId, actionId);
  }

  /// Show an OS notification for an escalation with inline action buttons.
  ///
  /// [payload] must be a valid [EscalationPushPayload].
  /// Actions are built from [payload.quickReplyOptions]; each option becomes
  /// one tappable button in the notification.
  ///
  /// Example:
  /// ```dart
  /// await EscalationNotifier.instance.showEscalationNotification(payload);
  /// ```
  Future<void> showEscalationNotification(EscalationPushPayload payload) async {
    if (!_initialized) await initialize();

    final notifId =
        (payload.channelId * 100000 + payload.escalationMessageId).abs() % 2147483647;
    final actionPayloadPrefix =
        '${payload.channelId}:${payload.escalationMessageId}:';

    NotificationDetails details;

    if (!kIsWeb && Platform.isAndroid) {
      final actions = payload.quickReplyOptions
          .map((opt) => AndroidNotificationAction(
                opt,
                opt,
                showsUserInterface: opt == 'Open',
              ))
          .toList();
      details = NotificationDetails(
        android: AndroidNotificationDetails(
          'tally_escalations',
          'Tally Escalations',
          channelDescription: 'Tally needs your input on a running task.',
          importance: Importance.max,
          priority: Priority.high,
          actions: actions,
        ),
      );
    } else if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
      // iOS/macOS: category registered in AppDelegate handles action buttons.
      details = const NotificationDetails(
        iOS: DarwinNotificationDetails(
          categoryIdentifier: 'tally_escalation',
        ),
        macOS: DarwinNotificationDetails(
          categoryIdentifier: 'tally_escalation',
        ),
      );
    } else {
      // Linux/desktop/web fallback — no action buttons.
      details = const NotificationDetails(
        linux: LinuxNotificationDetails(),
      );
    }

    await _plugin.show(
      notifId,
      'Tally needs you',
      payload.question,
      details,
      payload: actionPayloadPrefix,
    );
  }
}
