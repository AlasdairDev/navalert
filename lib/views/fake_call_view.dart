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

    // TODO (UI Team): this whole screen is [EDIT]-heavy and the HIGHEST-value
    // one to make convincing — it must look like the phone's REAL incoming-call
    // UI (safety depends on the illusion). DELIBERATE EXCEPTION TO THE THEME:
    // the dark background, white text, and red/green call buttons below are
    // intentionally NOT NavAlert purple — they mimic the native dialer. Match
    // the OS dialer styling here; do not pull app theme colors into it.
    return PopScope(
      // DO NOT MODIFY LOGIC: hardware Back and the edge-swipe MUST tear the
      // call down, not merely hide it. This screen used to pop with no cleanup
      // at all — the ringtone kept playing and NavAlert stayed drawn over the
      // lock screen with no visible call left to end it, which is the exact
      // opposite of a discreet escape. Leaving canPop true is deliberate: the
      // rider must always be able to leave; only the teardown is enforced.
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) em.endFakeCall();
      },
      child: Scaffold(
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
                // DO NOT MODIFY LOGIC: decline → pop, and the PopScope above
                // runs endFakeCall (audio + lock-screen window); answer → play
                // the chosen recording + start the call timer. Restyle the
                // buttons, keep the handlers. Red/green are the universal call
                // colours — keep.
                // Popping FIRST is deliberate: the native teardown is slow, and
                // awaiting it before popping made End feel unresponsive. The
                // teardown now hangs off the PopScope instead of these two
                // handlers, so it runs on EVERY exit — button, hardware Back,
                // or edge-swipe — and can no longer be bypassed.
                _roundButton(Icons.call_end, Colors.red, () {
                  Navigator.of(this.context).pop();
                }),
                _roundButton(Icons.call, Colors.green, () async {
                  final rec = app.selectedRecording;
                  await em.answerFakeCall(rec?.filePath);
                  _tick();
                }),
              ])
            else
              // Wrapped in a full-width Row like the incoming-call branch:
              // without it the Column shrinks to its widest child and the
              // whole screen jumps left the instant the call is answered,
              // which instantly breaks the "real dialer" illusion.
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                // Pop only; the PopScope tears down (see the incoming branch).
                _roundButton(Icons.call_end, Colors.red, () {
                  Navigator.of(this.context).pop();
                }),
              ]),
              const SizedBox(height: 40),
            ]),
          ),
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
