import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// UC-8 Exception 2 — "Interface Override Blocked".
///
/// Makes the fake call (R7) reachable when NavAlert is not in the foreground
/// or the screen is locked, which is the situation the feature actually has
/// to work in: a rider being harassed presses the volume shortcut with the
/// phone in their lap or pocket, not with the app open.
///
/// Two mechanisms, deliberately layered so the feature degrades instead of
/// disappearing:
///
///  1. A **full-screen-intent notification** on a high-importance "call"
///     channel. Android launches the call UI itself, over the keyguard.
///     This is what dialer apps use; SYSTEM_ALERT_WINDOW would need a
///     manual per-app toggle buried in Settings and is increasingly
///     restricted, so it is the wrong tool here.
///  2. **showWhenLocked / turnScreenOn** on the activity, so once NavAlert is
///     showing it stays visible above the lock screen and the screen does not
///     sleep mid-call.
///
/// If the OS refuses the full-screen intent (Android 14+ can withhold it from
/// apps it does not classify as calling apps), the notification still posts as
/// a heads-up alert and the audio + vibration from [SoundService] still play —
/// the paper's specified fallback.
class FakeCallScreenService {
  FakeCallScreenService._();
  static final FakeCallScreenService instance = FakeCallScreenService._();

  static const _channel = MethodChannel('navalert/lockscreen');
  static const int _notificationId = 1002;

  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _initFuture;

  Future<void> _init() => _initFuture ??= _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );

  /// Raises the incoming-call UI. Never throws: a failure here must not stop
  /// the caller from showing the in-app call screen (UC-8 Exception 1).
  Future<void> present(String callerName) async {
    try {
      await _channel.invokeMethod('showOverLockScreen');
    } catch (_) {
      // Older/odd OEM builds may not honour it — the notification still works.
    }
    // Only raise the notification when NavAlert is not already on screen.
    // A full-screen-intent heads-up is a focusable window drawn above the
    // activity: posting it while the in-app call screen is visible steals
    // touch input, leaving the rider unable to answer or hang up. When the
    // app is resumed the in-app screen is already the call UI, so the
    // notification adds nothing.
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    try {
      await _init();
      await _plugin.show(
        _notificationId,
        callerName,
        'Incoming call',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'navalert_fake_call',
            'Fake Call',
            channelDescription:
                'Simulated incoming call used to leave unsafe situations.',
            importance: Importance.max,
            priority: Priority.max,
            // The part that actually beats the lock screen.
            fullScreenIntent: true,
            category: AndroidNotificationCategory.call,
            autoCancel: false,
            visibility: NotificationVisibility.public,
            ticker: 'Incoming call',
          ),
        ),
      );
    } catch (_) {
      // Notifications denied — in-app call screen and audio still run.
    }
  }

  /// Tears the call UI down and stops NavAlert showing over the lock screen.
  Future<void> dismiss() async {
    try {
      await _plugin.cancel(_notificationId);
    } catch (_) {}
    try {
      await _channel.invokeMethod('clearLockScreen');
    } catch (_) {}
  }
}
