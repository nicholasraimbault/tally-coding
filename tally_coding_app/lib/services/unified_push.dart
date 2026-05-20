// tally_coding_app/lib/services/unified_push.dart
//
// Sprint 46 B8: real UnifiedPush implementation.
// Opens the distributor picker on Android, registers the app, and returns
// the endpoint URL the orchestrator should use for push delivery.
//
// API notes (unifiedpush 5.0.2):
//   - Callbacks-based, not stream-based. UnifiedPush.initialize() wires up
//     onNewEndpoint / onRegistrationFailed / onUnregistered callbacks.
//   - UnifiedPush.registerAppWithDialog() is marked @Deprecated("Use
//     UnifiedPushUI") but remains fully functional in 5.0.2; we use it
//     rather than re-implementing the picker manually.
//   - initialize() MUST be called before registerApp* so the callbacks are
//     in place before the distributor can fire NEW_ENDPOINT.
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:unifiedpush/unifiedpush.dart';

class UnifiedPushManager {
  UnifiedPushManager._();
  static final UnifiedPushManager instance = UnifiedPushManager._();

  /// On Android, opens the UnifiedPush distributor picker, registers
  /// our app for messages, and waits for the distributor to hand back
  /// an endpoint URL we can give the orchestrator.
  ///
  /// Returns null if the user cancels, no distributor is installed, or
  /// registration fails within the 15-second timeout.
  /// On non-Android platforms, returns null silently.
  ///
  /// Example:
  /// ```dart
  /// final endpoint = await UnifiedPushManager.instance
  ///     .registerAndPickEndpoint(context);
  /// if (endpoint != null) {
  ///   // send endpoint to the orchestrator
  /// }
  /// ```
  Future<String?> registerAndPickEndpoint(BuildContext context) async {
    if (!Platform.isAndroid) return null;

    final completer = Completer<String?>();

    // Wire up callbacks before calling registerApp* so NEW_ENDPOINT is
    // captured even if it fires synchronously during registration.
    await UnifiedPush.initialize(
      onNewEndpoint: (String endpoint, String instance) {
        if (!completer.isCompleted) completer.complete(endpoint);
      },
      onRegistrationFailed: (String instance) {
        if (!completer.isCompleted) completer.complete(null);
      },
      onUnregistered: (String instance) {
        if (!completer.isCompleted) completer.complete(null);
      },
    );

    if (!context.mounted) return null;
    try {
      // ignore: deprecated_member_use
      await UnifiedPush.registerAppWithDialog(context, 'tally-default'); // ignore: use_build_context_synchronously
    } catch (e) {
      // Thrown when no distributor is installed and the built-in "no
      // distributor" dialog has already been dismissed. Show our own
      // branded dialog with F-Droid guidance.
      if (!context.mounted) return null;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('No UnifiedPush distributor installed'),
          content: const Text(
            'Install one from F-Droid (ntfy recommended) to receive '
            'push notifications. Tally never sends your notification '
            'content to Google.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return null;
    }

    // Wait up to 15 s for the distributor to call back with the endpoint.
    final endpoint = await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => null,
    );
    return endpoint;
  }
}
