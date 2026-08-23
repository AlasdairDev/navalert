import 'dart:async';

import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../services/hardware_buttons.dart';
import '../services/home_widget_service.dart';
import '../services/trip_notification_service.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/emergency_viewmodel.dart';
import '../viewmodels/history_viewmodel.dart';
import '../viewmodels/trip_viewmodel.dart';
import 'active_trip_view.dart';
import 'emergency_view.dart';
import 'fake_call_view.dart';
import 'favorites_view.dart';
import 'history_view.dart';
import 'home_view.dart';
import 'settings_view.dart';

/// Main navigation shell (Figure 19) — bottom bar with
/// History · Favorites · Home · Emergency · Settings.
/// Also wires the volume-button emergency shortcuts:
/// triple Volume-Up → SOS, triple Volume-Down → Fake Call.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] IndexedStack of the 5 tabs · BottomNavigationBar onTap (index +
///         History-refresh + Emergency SMS-prewarm) · HardwareButtons SOS/
///         fake-call stream subscriptions. Keep the 5 tabs and their order.
///  [EDIT] tab icons & labels, bottom-bar colors/shape (mostly via theme's
///         bottomNavigationBarTheme), selected-tab highlight.
///  [WANT] center FAB for "start trip", badge on Emergency, animated tab
///         transitions, a custom nav bar.
class ShellView extends StatefulWidget {
  const ShellView({super.key});

  @override
  State<ShellView> createState() => _ShellViewState();
}

class _ShellViewState extends State<ShellView> {
  int _index = 2; // Home
  bool _resuming = false; // guards the "trip in progress" resume bar
  StreamSubscription? _sosSub;
  StreamSubscription? _fakeSub;
  StreamSubscription? _widgetSub;

  @override
  void initState() {
    super.initState();
    _wireHomeWidgetShortcuts();
    _wireLockScreenSos();
    // ─── DO NOT MODIFY LOGIC (entire block) ───────────────────────────────
    // These streams are fed by the native MediaButtonService (screen-off
    // triple-Volume shortcuts, R7/R8). Removing/reordering start() or either
    // .listen breaks the emergency shortcuts. The ONLY [EDIT] parts here are
    // the SnackBar copy and, in _launchFakeCall, how the call screen looks.
    HardwareButtons.instance.start();
    // onError is required, not cosmetic: an error on either stream would
    // otherwise be unhandled AND cancel the subscription, silently killing the
    // screen-off volume shortcut for the rest of the session — the rider would
    // press Volume-Up x3 in an emergency and nothing would happen.
    _sosSub = HardwareButtons.instance.onSosShortcut.listen((_) {
      if (!mounted) return;
      final em = context.read<EmergencyViewModel>();
      em.fireSos();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Volume-Up ×3 - sending SOS to your contacts…')));
    },
        onError: (e) => debugPrint('NavAlert: SOS shortcut stream error — $e'),
        cancelOnError: false);
    _fakeSub = HardwareButtons.instance.onFakeCallShortcut.listen((_) {
      if (!mounted) return;
      _launchFakeCall();
    },
        onError: (e) =>
            debugPrint('NavAlert: fake-call shortcut stream error — $e'),
        cancelOnError: false);
    // ──────────────────────────────────────────────────────────────────────
  }

  /// Routes taps on the home-screen App Widget (Batch 3). The SOS button
  /// launches the app with the `navalert://sos` URI; both the cold-launch case
  /// (initiallyLaunchedFromHomeWidget) and the warm case (widgetClicked stream)
  /// fire the same SOS flow as the volume shortcut. A plain body tap
  /// (`navalert://open`) just brings the app forward — no action needed.
  ///
  /// DO NOT MODIFY LOGIC (both methods below): removing/reordering either
  /// subscription, or the isSosUri gate, breaks the widget's one-tap SOS. The
  /// only [EDIT] part is the SnackBar copy in _handleWidgetUri.
  /// Routes the lock-screen notification's "SOS — send my location" action.
  ///
  /// DO NOT MODIFY LOGIC: wired HERE, not in TripViewModel, because the shell
  /// is the one place that owns every external SOS trigger (volume shortcut,
  /// home-screen widget, and now the notification) and can reach
  /// EmergencyViewModel. TripViewModel has no SosService of its own, and giving
  /// it one would create a SECOND service with its own independent retry queue
  /// — two timers retrying the same emergency, sending duplicate SMS.
  void _wireLockScreenSos() {
    TripNotificationService.instance.onSos = () {
      if (!mounted) return;
      final em = context.read<EmergencyViewModel>();
      final tripId = context.read<TripViewModel>().trip?.tripId;
      em.fireSos(tripId: tripId);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Lock screen SOS - sending your location…')));
    };
  }

  void _wireHomeWidgetShortcuts() {
    // Same reasoning as the volume shortcuts: an unhandled error here would
    // cancel the subscription and silently disable the widget's one-tap SOS.
    HomeWidget.initiallyLaunchedFromHomeWidget()
        .then(_handleWidgetUri)
        .catchError(
            (e) => debugPrint('NavAlert: widget launch URI unavailable — $e'));
    _widgetSub = HomeWidget.widgetClicked.listen(_handleWidgetUri,
        onError: (e) => debugPrint('NavAlert: widget click stream error — $e'),
        cancelOnError: false);
  }

  void _handleWidgetUri(Uri? uri) {
    if (!mounted || !HomeWidgetService.isSosUri(uri)) return;
    final em = context.read<EmergencyViewModel>();
    em.fireSos();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Widget SOS - sending your location to your contacts…')));
  }

  Future<void> _launchFakeCall() async {
    final em = context.read<EmergencyViewModel>();
    // Repeated triple-Volume-Down presses must not stack call screens — push
    // only when this trigger actually started the call.
    final started = await em.startFakeCall(
        callerName: context.read<AppViewModel>().fakeCallConfig.callerName);
    if (!started || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true, builder: (_) => const FakeCallView()));
  }

  @override
  void dispose() {
    _sosSub?.cancel();
    _fakeSub?.cancel();
    _widgetSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const pages = [
      HistoryView(),
      FavoritesView(),
      HomeView(),
      EmergencyView(),
      SettingsView(),
    ];
    // DO NOT MODIFY LOGIC: a trip stays active in the ViewModel even if the
    // ActiveTripView route is lost when Android backgrounds/kills the activity.
    // This bar lets the rider get back to the live trip instead of being
    // stranded on the shell. Keep the isActive check + the re-push.
    final tripActive = context.watch<TripViewModel>().isActive;
    return Scaffold(
      // DO NOT MODIFY LOGIC: IndexedStack keeps all 5 tabs alive (state is
      // preserved across tab switches). Keep the 5 pages and their order.
      // GUI Page 13.5 — the resume-trip affordance is a CENTRED PILL floating
      // just above the bottom navigation, not a full-width bar stealing a strip
      // off the top of every tab. Mockup geometry (360x780 dp): pill x=88-272
      // (w=184), y=678-716 (h=38), bottom nav starts y=730, so the pill sits
      // 14 dp above it. Overlaying it in a Stack instead of stacking it in a
      // Column also stops it from shoving the whole tab down when a trip
      // starts. It stays in the SHELL, not on Home, so a rider who wandered
      // into Settings mid-trip still has the way back.
      body: Stack(children: [
        IndexedStack(index: _index, children: pages),
        if (tripActive)
          Positioned(
            left: 0,
            right: 0,
            bottom: 14,
            child: Center(
              // Keep the onTap that re-opens ActiveTripView.
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(19),
                  border: Border.all(color: NavAlertColors.accent, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                        color:
                            NavAlertColors.primaryButton.withValues(alpha: 0.6),
                        blurRadius: 16,
                        spreadRadius: 1),
                  ],
                ),
                child: Material(
                  color: NavAlertColors.primaryButton,
                  borderRadius: BorderRadius.circular(19),
                  elevation: 4,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(19),
                    // DO NOT MODIFY LOGIC: in-flight guard. Two taps stacked TWO
                    // ActiveTripView routes; sliding to stop then popped only the
                    // top one, leaving a second monitoring screen bound to a trip
                    // that had already ended — a ghost trip the rider cannot make
                    // sense of.
                    onTap: () {
                      if (_resuming) return;
                      _resuming = true;
                      Navigator.of(context)
                          .push(MaterialPageRoute(
                              builder: (_) => const ActiveTripView()))
                          .whenComplete(() {
                        if (mounted) _resuming = false;
                      });
                    },
                    child: const SizedBox(
                      height: 38,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 18),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.location_on,
                              size: 18, color: Colors.white),
                          SizedBox(width: 8),
                          Text('View Active Trip',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) {
          setState(() => _index = i);
          // DO NOT MODIFY LOGIC: History refreshes when its tab opens, and the
          // SMS permission is pre-warmed when Emergency opens — keep both.
          if (i == 0) context.read<HistoryViewModel>().load();
          if (i == 3) context.read<EmergencyViewModel>().ensureSmsReady();
        },
        // Keep 5 tabs in this order (History · Favorites · Home · Emergency ·
        // Settings).
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'History'),
          BottomNavigationBarItem(
              icon: Icon(Icons.star_border), label: 'Favorites'),
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(
              icon: Icon(Icons.warning_amber), label: 'Emergency'),
          BottomNavigationBarItem(
              icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
