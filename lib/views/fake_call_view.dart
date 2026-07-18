import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/emergency_viewmodel.dart';

/// Use Case UC-8 — Activate Fake Call: a realistic full-screen incoming
/// call that plays the configured recording once "answered".
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] answer (green) → em.answerFakeCall(recording) + start timer ·
///         decline/end (red) → em.endFakeCall + pop · caller name from
///         app.fakeCallConfig.callerName. Must look like a REAL incoming call.
///  [EDIT] this is the highest-value screen to make convincing: mimic the
///         native dialer (background, avatar, name/number typography, button
///         icons/positions, "Incoming call"/timer text). All cosmetic.
///  [WANT] slide-to-answer like iOS, ringback vibration UI, blurred wallpaper,
///         match the user's actual OS dialer style.
class FakeCallView extends StatefulWidget {
  const FakeCallView({super.key});

  @override
  State<FakeCallView> createState() => _FakeCallViewState();
}

class _FakeCallViewState extends State<FakeCallView> {
  int _seconds = 0;

  @override
  Widget build(BuildContext context) {
    final em = context.watch<EmergencyViewModel>();
    final app = context.watch<AppViewModel>();
    final caller = app.fakeCallConfig.callerName;

    return Scaffold(
      backgroundColor: const Color(0xFF101418),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(children: [
            const SizedBox(height: 40),
            Text(em.fakeCallAnswered ? _fmt(_seconds) : 'Incoming call',
                style: const TextStyle(color: Colors.white54)),
            const SizedBox(height: 12),
            CircleAvatar(
              radius: 52,
              backgroundColor: Colors.blueGrey.shade700,
              child: Text(caller.isEmpty ? '?' : caller[0].toUpperCase(),
                  style: const TextStyle(fontSize: 44, color: Colors.white)),
            ),
            const SizedBox(height: 16),
            Text(caller,
                style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
            const Text('Mobile · Philippines',
                style: TextStyle(color: Colors.white38)),
            const Spacer(),
            if (!em.fakeCallAnswered)
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _roundButton(Icons.call_end, Colors.red, () async {
                  await em.endFakeCall();
                  if (mounted) Navigator.of(this.context).pop();
                }),
                _roundButton(Icons.call, Colors.green, () async {
                  final rec = app.selectedRecording;
                  await em.answerFakeCall(rec?.filePath);
                  _tick();
                }),
              ])
            else
              _roundButton(Icons.call_end, Colors.red, () async {
                await em.endFakeCall();
                if (mounted) Navigator.of(this.context).pop();
              }),
            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }

  void _tick() async {
    while (mounted && context.read<EmergencyViewModel>().fakeCallAnswered) {
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) setState(() => _seconds++);
    }
  }

  String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  Widget _roundButton(IconData icon, Color color, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 32),
        ),
      );
}
