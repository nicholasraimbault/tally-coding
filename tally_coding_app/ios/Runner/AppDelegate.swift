import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // B4: register the tally_escalation notification category so iOS renders
    // inline action buttons matching the quick_reply_options from the push payload.
    // Action identifiers here are static placeholders; the Flutter layer maps
    // the chosen identifier back to the actual option text via the payload.
    //
    // NOTE: iOS APNs static categories use fixed action identifiers. The option
    // labels shown to the user ("2 decimals", "Keep 4") match the quick_reply_options
    // from the payload only when a Notification Content Extension is in place
    // (sub-project D territory). For MVP, the "Open" action is always shown with
    // the correct label; the other actions show "Option 1"/"Option 2" as
    // iOS-system-native labels.
    let openAction = UNNotificationAction(
      identifier: "Open",
      title: "Open",
      options: [.foreground]
    )
    // Dynamic action slots: the first two quick-reply options always occupy
    // these slots. The Flutter EscalationNotifier sets concrete labels via
    // the flutter_local_notifications Android path; on iOS the category is
    // static. For A/B quick replies with 2 options:
    let option1Action = UNNotificationAction(
      identifier: "ESCALATION_OPTION_1",
      title: "Option 1",   // overridden at runtime by notification content extension (future D)
      options: []
    )
    let option2Action = UNNotificationAction(
      identifier: "ESCALATION_OPTION_2",
      title: "Option 2",
      options: []
    )
    let escalationCategory = UNNotificationCategory(
      identifier: "tally_escalation",
      actions: [option1Action, option2Action, openAction],
      intentIdentifiers: [],
      options: []
    )
    UNUserNotificationCenter.current().setNotificationCategories([escalationCategory])

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
