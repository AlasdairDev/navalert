import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/hardware_buttons.dart';
import '../viewmodels/emergency_viewmodel.dart';
import '../viewmodels/history_viewmodel.dart';
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
  }

  Future<void> _launchFakeCall() async {
    final em = context.read<EmergencyViewModel>();
    await em.startFakeCall();
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
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) {
          setState(() => _index = i);
          // IndexedStack keeps pages alive, so refresh Trip History
          // whenever its tab is opened — otherwise trips completed
          // after startup would never appear.
          if (i == 0) context.read<HistoryViewModel>().load();
        },
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

