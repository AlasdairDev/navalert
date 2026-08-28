import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Tells the commuter what an SOS actually did, from outside the app.
///
/// WHY THIS EXISTS
/// `EmergencyViewModel.fireSos()` records its outcome in `statusMessage`, and
/// the volume-shortcut handler shows a SnackBar. Both draw INSIDE the app's
/// own window. The shortcut exists precisely for a pocketed phone with the
/// screen off, so at the moment it matters there is no window to draw on: the
/// SOS could send correctly, or fail because no contacts are saved, and the
/// commuter would see exactly the same thing — nothing.
///
/// DISCRETION IS PRESERVED. The channel is silent by construction: no sound,
/// no vibration, no heads-up banner, no screen wake. It appears in the shade
/// when the phone is next looked at, which is what makes an SOS verifiable
/// after the fact without announcing itself while it happens.
///
/// Importance is DEFAULT rather than LOW deliberately — below DEFAULT, OEM
/// skins (HyperOS/MIUI) file a notification into a collapsed "silent" bucket
/// that is hidden on the lock screen, which would defeat the entire purpose.
/// Silence comes from `playSound: false` + `enableVibration: false`, not from
/// lowering importance.
class SosResultNotification {
  SosResultNotification._();
  static final SosResultNotification instance = SosResultNotification._();

  static const int _id = 1002;
  static const String _channelId = 'navalert_sos_result';

  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _initFuture;

  /// Off in tests: there is no platform channel under `flutter test`, and a
  /// safety path must never fail because its receipt could not be drawn.
  @visibleForTesting
  static bool enabled = true;

  Future<void> _init() => _initFuture ??= _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );

  /// Posts the outcome of an SOS. [message] is the same text the Emergency
  /// screen shows, so the two can never disagree.
  Future<void> show({required String message, required bool isError}) async {
    if (!enabled) return;
    try {
      await _init();
      await _plugin.show(
        _id,
        isError ? 'SOS could not be sent' : 'Emergency SMS sent',
        message,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'SOS result',
            channelDescription:
                'Confirms whether an emergency SMS was sent, without making a '
                'sound.',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            playSound: false,
            enableVibration: false,
            onlyAlertOnce: true,
            visibility: NotificationVisibility.public,
            styleInformation: BigTextStyleInformation(message),
          ),
        ),
      );
    } catch (e) {
      // Never let a failed receipt mask the SOS itself.
      debugPrint('NavAlert: could not post SOS result notification — $e');
    }
  }
}
