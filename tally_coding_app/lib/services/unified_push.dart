// tally_coding_app/lib/services/unified_push.dart
//
// Sprint 46 B7: stub only — B8 ships the real Android/UnifiedPush
// implementation.  This file exists so notifications_screen.dart
// compiles; at runtime _addAndroid returns null and the device-add
// flow is a no-op until B8 lands.
import 'package:flutter/material.dart';

class UnifiedPushManager {
  UnifiedPushManager._();
  static final UnifiedPushManager instance = UnifiedPushManager._();

  /// Sprint 46 B8: real implementation. B7 ships a stub that returns null.
  Future<String?> registerAndPickEndpoint(BuildContext context) async => null;
}
