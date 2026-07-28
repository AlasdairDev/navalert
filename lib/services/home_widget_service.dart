import 'package:home_widget/home_widget.dart';

/// Home-screen App Widget (Batch 3) — shows live trip status on the Android
/// launcher and offers a one-tap SOS without opening the app.
///
/// Data is pushed to the native NavAlertWidgetProvider through the home_widget
/// bridge (SharedPreferences under the hood). The provider reads these keys and
/// renders the RemoteViews. Tapping the widget body opens the app; tapping SOS
/// launches the app with the `navalert://sos` URI, which [widgetSosUris] routes
/// to fireSos (see ShellView).
class HomeWidgetService {
  HomeWidgetService._();
  static final HomeWidgetService instance = HomeWidgetService._();

  static const _android = 'NavAlertWidgetProvider';

  /// Pushes the active-trip state to the widget.
  Future<void> showTrip({
    required String destination,
    required double distanceM,
    double? etaMinutes,
    required String status,
  }) async {
    final dist = distanceM >= 1000
        ? '${(distanceM / 1000).toStringAsFixed(1)} km away'
        : '${distanceM.toStringAsFixed(0)} m away';
    final eta = etaMinutes == null ? '' : 'ETA ${etaMinutes.round()} min';
    await _save({
      'active': 'true',
      'status': status,
      'destination': destination,
      'distance': dist,
      'eta': eta,
    });
  }

  /// Resets the widget to its idle "tap to plan a trip" state.
  Future<void> showIdle() async {
    await _save({
      'active': 'false',
      'status': 'No active trip',
      'destination': 'Tap to plan your commute',
      'distance': '',
      'eta': '',
    });
  }

  Future<void> _save(Map<String, String> data) async {
    try {
      for (final e in data.entries) {
        await HomeWidget.saveWidgetData<String>(e.key, e.value);
      }
      await HomeWidget.updateWidget(androidName: _android);
    } catch (_) {
      // No widget added / non-Android — nothing to update.
    }
  }

  /// True when a launch/click URI is the widget's SOS button.
  static bool isSosUri(Uri? uri) => uri != null && uri.host == 'sos';
}
