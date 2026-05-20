// tally_coding_app/lib/services/desktop_notifier.dart
//
// Sprint 46 B7: stub only — B9 ships the real Linux libnotify
// implementation.  This file exists so notifications_screen.dart
// compiles; at runtime requestPermission returns false and
// showNotification is a no-op until B9 lands.
class DesktopNotifier {
  DesktopNotifier._();
  static final DesktopNotifier instance = DesktopNotifier._();

  /// Sprint 46 B9: real implementation. B7 ships a stub that returns false.
  Future<bool> requestPermission() async => false;

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
  }) async {}
}
