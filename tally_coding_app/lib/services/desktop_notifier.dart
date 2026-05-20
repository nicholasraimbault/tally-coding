// tally_coding_app/lib/services/desktop_notifier.dart
//
// Sprint 46 B9: real Linux libnotify implementation via
// flutter_local_notifications (LinuxFlutterLocalNotificationsPlugin).
import 'dart:io' show Platform;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class DesktopNotifier {
  DesktopNotifier._();
  static final DesktopNotifier instance = DesktopNotifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _inited = false;

  Future<bool> requestPermission() async {
    if (!Platform.isLinux) return false;
    if (!_inited) {
      const init = InitializationSettings(
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      );
      await _plugin.initialize(init);
      _inited = true;
    }
    // libnotify doesn't require explicit permission; treat as granted.
    return true;
  }

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!Platform.isLinux) return;
    if (!_inited) await requestPermission();
    await _plugin.show(
      id,
      title,
      body,
      const NotificationDetails(
        linux: LinuxNotificationDetails(),
      ),
    );
  }
}
