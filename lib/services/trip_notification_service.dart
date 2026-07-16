import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Figure 25 — Lock Screen Widget.
///
/// Shows the active trip directly on the lock screen as an ongoing
/// notification: destination name, remaining distance and ETA with a
/// "Monitoring" indicator, plus "Open in App" and "End trip" actions —
/// so the rider can stop the trip without unlocking the device.
class TripNotificationService {
  TripNotificationService._();
  static final TripNotificationService instance = TripNotificationService._();

  static const int _tripNotificationId = 1001;
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Called when the rider taps "End trip" on the lock-screen widget.
  VoidCallback? onEndTrip;

  Future<void> init() async {
    if (_initialized) return;
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        if (response.actionId == 'end_trip') onEndTrip?.call();
      },
    );
    _initialized = true;
  }

  Future<void> showTrip({
    required String destination,
    required double distanceM,
    double? etaMinutes,
  }) async {
    await init();
    final distText = distanceM >= 1000
        ? '${(distanceM / 1000).toStringAsFixed(1)} km away'
        : '${distanceM.toStringAsFixed(0)} m away';
    final etaText = etaMinutes == null
        ? ''
        : ' · ETA ${etaMinutes.round()} min';
    await _plugin.show(
      _tripNotificationId,
      'Approaching $destination',
      '$distText$etaText  •  Monitoring',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'navalert_trip',
          'Trip Monitoring',
          channelDescription:
              'Active trip status shown on the lock screen (Figure 25).',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          showWhen: false,
          visibility: NotificationVisibility.public,
          category: AndroidNotificationCategory.navigation,
          actions: [
            AndroidNotificationAction('open_app', 'Open in App',
                showsUserInterface: true),
            AndroidNotificationAction('end_trip', 'End trip',
                showsUserInterface: true),
          ],
        ),
      ),
    );
  }

  Future<void> cancel() => _plugin.cancel(_tripNotificationId);
}
