import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../viewmodels/app_viewmodel.dart';
import 'onboarding_flow.dart';
import 'shell.dart';

/// Figure 14 — Launch Screen. Shows the NavAlert brand, waits for the
/// local database, then routes to onboarding or the main shell.
class LaunchView extends StatefulWidget {
  const LaunchView({super.key});

  @override
  State<LaunchView> createState() => _LaunchViewState();
}

class _LaunchViewState extends State<LaunchView> {
  @override
  void initState() {
    super.initState();
    _go();
  }

  Future<void> _go() async {
    final app = context.read<AppViewModel>();
    final start = DateTime.now();
    while (!app.loaded) {
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
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A0E2B), NavAlertColors.background],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: NavAlertColors.surface,
                  boxShadow: [
                    BoxShadow(
                        color: NavAlertColors.primary.withValues(alpha: 0.5),
                        blurRadius: 40),
                  ],
                ),
                child: const Icon(Icons.alarm_on,
                    size: 84, color: NavAlertColors.accent),
              ),
              const SizedBox(height: 20),
              const Text('NavAlert',
                  style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
              const SizedBox(height: 6),
              const Text('Never miss your stop again.',
                  style: TextStyle(color: NavAlertColors.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}
