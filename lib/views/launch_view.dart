import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../viewmodels/app_viewmodel.dart';
import 'onboarding_flow.dart';
import 'shell.dart';

/// Figure 14 — Launch Screen. Shows the NavAlert brand, waits for the
/// local database, then routes to onboarding or the main shell.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] _go(): wait for AppViewModel.loaded, then route to TutorialView
///         (first run) or ShellView. Keep the "wait for load" gate.
///  [EDIT] the whole splash look — logo/icon (currently Icons.alarm_on),
///         "NavAlert" wordmark, tagline, gradient, the 1400 ms min-display.
///         Prime spot to drop in your real logo image asset.
///  [WANT] animated logo reveal, progress indicator, brand motion.
class LaunchView extends StatefulWidget {
  const LaunchView({super.key});

  @override
  State<LaunchView> createState() => _LaunchViewState();
}

class _LaunchViewState extends State<LaunchView> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _go();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
  }

  // DO NOT MODIFY LOGIC: the splash gate — waits for AppViewModel to finish
  // loading (DB/settings), then routes to onboarding on first run or straight
  // to the app afterwards. Keep the load-wait + the onboardingCompleted branch.
  // The 1400 ms minimum is just so the splash doesn't flash — that value and
  // everything visual are [EDIT].
  //
  // Fail-safe: never wait forever. If init genuinely hangs on a device (e.g. a
  // stalled encrypted-DB open on some OEM ROMs), proceed after [_maxSplashWait]
  // so the rider sees the app instead of an endless loading screen. This is the
  // groupmate-reported "stuck on the loading screen" guard — do not remove it.
  static const _maxSplashWait = Duration(seconds: 12);
  Future<void> _go() async {
    final app = context.read<AppViewModel>();
    final start = DateTime.now();
    while (!app.loaded && DateTime.now().difference(start) < _maxSplashWait) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
    }
    final elapsed = DateTime.now().difference(start);
    if (elapsed < const Duration(milliseconds: 1400)) {
      await Future.delayed(const Duration(milliseconds: 1400) - elapsed);
    }
    if (!mounted) return;
    final next = app.appState.onboardingCompleted
        ? const ShellView()
        : const TutorialView();
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => next));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: const Duration(milliseconds: 500),
        child: Image.asset(
          'assets/images/branding/launch_splash.png',
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
        ),
      ),
    );
  }
}
