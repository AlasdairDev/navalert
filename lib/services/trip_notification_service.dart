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
  Future<void>? _initFuture;

  /// Called when the rider taps "End trip" on the lock-screen widget.
  VoidCallback? onEndTrip;

  /// Called when the rider taps "SOS — send my location" on the lock-screen
  /// widget.
  ///
  /// DO NOT MODIFY LOGIC: this fires the SAME `fireSos` path as the on-screen
  /// button and the volume shortcut, so its in-flight guard already prevents
  /// duplicate SMS if the notification is tapped twice.
  ///
  /// LIMITATION, stated rather than hidden: this is delivered through
  /// `onDidReceiveNotificationResponse`, which only runs while the Flutter
  /// engine is alive. With the app swiped away the tap re-launches the app
  /// (`showsUserInterface: true`) and the SOS fires once it is up. A true
  /// headless send from a killed process needs a background isolate with its
  /// own database and platform-channel setup — the volume shortcut and the
  /// home-screen widget remain the fully headless SOS paths.
  VoidCallback? onSos;

  /// Idempotent under concurrency: main() fires this without awaiting and
  /// showTrip() awaits it again — caching the Future guarantees
  /// FlutterLocalNotificationsPlugin.initialize() runs exactly once even
  /// if both callers overlap during the startup window.
  Future<void> init() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        if (response.actionId == 'end_trip') onEndTrip?.call();
        if (response.actionId == 'sos_send') onSos?.call();
      },
    );
  }

  String? _lastTitle;
  String? _lastBody;

  /// The exact text shown on the lock screen (Figure 25). Pure and separated
  /// from the plugin call so the dedupe behaviour is unit-testable.
  ///
  /// Sub-kilometre distance is rounded to 10 m. GPS fixes arrive every second,
  /// and whole-metre text changed on almost every one of them, so this cuts
  /// roughly ten out of eleven updates in the final kilometre for a difference
  /// the rider cannot perceive on a lock-screen line.
  ///
  /// Android always renders `title` bold/prominent and `body` as the lighter
  /// line beneath it — the distance is the one number a half-asleep rider
  /// needs at a glance, so it takes the bold title slot; "Approaching X" and
  /// the Monitoring status move to the secondary line.
  static ({String title, String body}) composeTripText({
    required String destination,
    required double distanceM,
    double? etaMinutes,
  }) {
    final distText = distanceM >= 1000
        ? '${(distanceM / 1000).toStringAsFixed(1)} km away'
        : '${(distanceM / 10).round() * 10} m away';
    final etaText =
        etaMinutes == null ? '' : ' · ETA ${etaMinutes.round()} min';
    return (
      title: '$distText$etaText',
      body: 'Approaching $destination  •  Monitoring',
    );
  }

  Future<void> showTrip({
    required String destination,
    required double distanceM,
    double? etaMinutes,
  }) async {
    await init();
    final text = composeTripText(
        destination: destination,
        distanceM: distanceM,
        etaMinutes: etaMinutes);
    final title = text.title;
    final body = text.body;

    // DO NOT MODIFY LOGIC: skip the post when nothing visible changed. This is
    // called on EVERY GPS fix (one per second), so a 2-3 hour Metro Manila
    // commute meant ~7,000-10,000 notification updates, nearly all of them
    // byte-identical — each a platform-channel round trip plus a
    // NotificationManager update. Stuck in traffic, the distance does not move
    // at all and every single one was redundant. R5/battery efficiency is a
    // headline claim of the paper; do not remove this guard.
    if (title == _lastTitle && body == _lastBody) return;
    _lastTitle = title;
    _lastBody = body;

    await _plugin.show(
      _tripNotificationId,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          // DO NOT MODIFY LOGIC: the "_v2" suffix is load-bearing, not tidying.
          // A NotificationChannel's importance is FIXED once the channel exists
          // on the device — Android deliberately ignores later changes so a
          // user's own setting is never overridden. The original channel was
          // created at IMPORTANCE_LOW, which Android 12+ files under "Silent",
          // and most devices hide silent notifications from the lock screen by
          // default. Raising `importance` alone would therefore have changed
          // NOTHING on any phone that had already run NavAlert; only a new
          // channel id makes the new importance take effect.
          'navalert_trip_v2',
          'Trip Monitoring',
          channelDescription:
              'Active trip status shown on the lock screen (Figure 25).',
          // DO NOT set a custom `icon:` here without re-testing on a RELEASE
          // build. The small icon falls back to the launcher icon, which is
          // opaque, so Android's alpha-mask rendering shows it as a filled
          // blob in the status bar — cosmetically wrong but harmless.
          //
          // A dedicated monochrome drawable was tried and REVERTED. The plugin
          // resolves `icon:` by NAME at runtime (getIdentifier), which R8
          // defeats in a minified release build: the id came back 0 and
          // Android then dropped the notification silently — no Dart exception
          // (showTrip returned normally and the trip started fine), just no
          // lock-screen widget at all. Verified by isolating this single line:
          // with it, notification 1001 was absent from `dumpsys notification`;
          // without it, the notification posts correctly. Losing Figure 25
          // outright is far worse than a blob, so the fallback stays.
          //
          // If you do want the monochrome icon: add the drawable, keep it from
          // being shrunk/renamed (res/raw/keep.xml with tools:keep), and prove
          // it on a `flutter build apk --release`, not a debug build.
          // DEFAULT, not LOW: Android 12+ buckets LOW as "Silent", and most
          // devices hide the Silent section from the lock screen — which is the
          // one place Figure 25 has to be readable, because the rider is asleep.
          // Not HIGH: that adds a heads-up banner, and this notification is
          // rewritten on every GPS fix. `onlyAlertOnce` below keeps the sound to
          // the first post, so the trip starts with one chime rather than a
          // buzz every few seconds for the whole commute.
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          showWhen: false,
          visibility: NotificationVisibility.public,
          category: AndroidNotificationCategory.navigation,
          // DO NOT MODIFY LOGIC: SOS is listed FIRST. Android collapses the
          // action row on narrow lock screens and drops the trailing actions,
          // so the emergency action must never be the one that gets cut.
          //
          // NOTE FOR THE UI TEAM: a notification cannot be styled like the
          // home-screen App Widget — Android renders it, and 12+ reformats
          // custom layouts. These are system-drawn text actions by necessity,
          // not by choice.
          actions: [
            AndroidNotificationAction('sos_send', 'SOS - send my location',
                showsUserInterface: true),
            AndroidNotificationAction('open_app', 'Open in App',
                showsUserInterface: true),
            AndroidNotificationAction('end_trip', 'End trip',
                showsUserInterface: true),
          ],
        ),
      ),
    );
  }

  /// Clears the dedupe cache as well — without that, the first update of the
  /// NEXT trip could match the last of the previous one and be skipped, so the
  /// lock-screen widget would never reappear.
  Future<void> cancel() {
    _lastTitle = null;
    _lastBody = null;
    return _plugin.cancel(_tripNotificationId);
  }
}
