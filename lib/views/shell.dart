import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../services/hardware_buttons.dart';
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
  StreamSubscription? _sosSub;
  StreamSubscription? _fakeSub;

  @override
  void initState() {
    super.initState();
    // ─── DO NOT MODIFY LOGIC (entire block) ───────────────────────────────
    // These streams are fed by the native MediaButtonService (screen-off
    // triple-Volume shortcuts, R7/R8). Removing/reordering start() or either
    // .listen breaks the emergency shortcuts. The ONLY [EDIT] parts here are
    // the SnackBar copy and, in _launchFakeCall, how the call screen looks.
    HardwareButtons.instance.start();
    _sosSub = HardwareButtons.instance.onSosShortcut.listen((_) {
      if (!mounted) return;
      final em = context.read<EmergencyViewModel>();
      em.fireSos();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Volume-Up ×3 — sending SOS to your contacts…')));
    });
    _fakeSub = HardwareButtons.instance.onFakeCallShortcut.listen((_) {
      if (!mounted) return;
      _launchFakeCall();
    });
    // ──────────────────────────────────────────────────────────────────────
  }

  Future<void> _launchFakeCall() async {
    final em = context.read<EmergencyViewModel>();
    await em.startFakeCall(
        callerName: context.read<AppViewModel>().fakeCallConfig.callerName);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true, builder: (_) => const FakeCallView()));
  }

  @override
  void dispose() {
    _sosSub?.cancel();
    _fakeSub?.cancel();
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
      body: Column(children: [
        if (tripActive)
          // TODO (UI Team): restyle this "resume trip" bar (colors, height,
          // icon, copy) — but keep the onTap that re-opens ActiveTripView.
          Material(
            color: NavAlertColors.primaryButton,
            child: InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ActiveTripView())),
              child: const SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(children: [
                    Icon(Icons.directions_walk, size: 18, color: Colors.white),
                    SizedBox(width: 10),
                    Expanded(
                        child: Text('Trip in progress — tap to return',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600))),
                    Icon(Icons.chevron_right, color: Colors.white),
                  ]),
                ),
              ),
            ),
          ),
        Expanded(child: IndexedStack(index: _index, children: pages)),
      ]),
      // TODO (UI Team): the bottom nav's look (colors, selected highlight,
      // shape, label visibility) is mostly driven by the theme's
      // bottomNavigationBarTheme — restyle there so it stays consistent.
      // Tab icons/labels below are [EDIT]; the onTap side-effects are logic.
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) {
          setState(() => _index = i);
          // DO NOT MODIFY LOGIC: History refreshes when its tab opens, and the
          // SMS permission is pre-warmed when Emergency opens — keep both.
          if (i == 0) context.read<HistoryViewModel>().load();
          if (i == 3) context.read<EmergencyViewModel>().ensureSmsReady();
        },
        // TODO (UI Team): tab icons + labels are free to restyle. Keep 5 tabs
        // in this order (History · Favorites · Home · Emergency · Settings).
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'History'),
          BottomNavigationBarItem(icon: Icon(Icons.star_border), label: 'Favorites'),
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(
              icon: Icon(Icons.warning_amber), label: 'Emergency'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

