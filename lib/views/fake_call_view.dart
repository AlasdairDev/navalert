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

  // ╔══════════════════════════════════════════════════════════════════════╗
  // ║ DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:                     ║
  // ║ SPAM-TAP DEBOUNCERS (isProcessing flags) for Answer and End.         ║
  // ║                                                                      ║
  // ║ UI TEAM: `_ticking` and `_leaving` are the in-flight guards. Restyle ║
  // ║ the call buttons however you like (size, colour, icon, position),    ║
  // ║ but keep `_leave` wired to the End/Decline button and keep the       ║
  // ║ `if (_ticking) return;` line at the top of Answer. Bypassing them    ║
  // ║ makes the call timer count several seconds per second and lets a     ║
  // ║ second End tap pop the screen UNDERNEATH this one — throwing the     ║
  // ║ rider out of their live trip.                                        ║
  // ╚══════════════════════════════════════════════════════════════════════╝
  // Panic-tap guards for the two call buttons.
  //
  // _ticking — the call timer must have exactly ONE loop. Answer is an async
  // handler, and `fakeCallAnswered` only flips the UI on the NEXT frame, so two
  // taps landing in the same frame both ran _tick(): the timer then counted two
  // seconds per second and the "real dialer" illusion — the entire point of this
  // screen — broke on sight.
  //
  // _leaving — End/Decline stays on screen for the whole pop transition, so a
  // second tap fired a SECOND Navigator.pop() that ate the route underneath
  // (ActiveTripView, or the shell tab). The rider tapped "end call" and was
  // thrown out of their live trip. This is the widest double-tap window in the
  // app, because the button never visually leaves until the route is gone.
  bool _ticking = false;
  bool _leaving = false;

  void _leave() {
    if (_leaving) return;
    _leaving = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final em = context.watch<EmergencyViewModel>();
    final app = context.watch<AppViewModel>();
    final caller = app.fakeCallConfig.callerName;

    // DELIBERATE EXCEPTION TO THE THEME:
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
      // ╔══════════════════════════════════════════════════════════════════╗
      // ║ DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:                 ║
      // ║ HARDWARE BACK-BUTTON GUARD + call teardown (UC-8).               ║
      // ║                                                                  ║
      // ║ UI TEAM: this screen is your highest-value restyle target — it   ║
      // ║ must look like the phone's REAL incoming-call UI, and the whole  ║
      // ║ `child:` subtree is yours (background, avatar, typography,       ║
      // ║ button shapes). But do NOT unwrap this PopScope or touch         ║
      // ║ `onPopInvokedWithResult`: that callback is the ONLY teardown     ║
      // ║ path, and it runs on every exit. Remove it and the ringtone      ║
      // ║ keeps playing with NavAlert stuck over the lock screen and no    ║
      // ║ visible call left to end — the opposite of a discreet escape.    ║
      // ╚══════════════════════════════════════════════════════════════════╝
      // canPop is HARD false: hardware Back and the edge-swipe can no longer
      // dismiss the call. The rider leaves through the red End button, which
      // uses Navigator.pop() — PopScope does not intercept programmatic pops,
      // so that exit (and the teardown below) still works. The teardown stays
      // on onPopInvokedWithResult so it runs on EVERY real exit and can never
      // be bypassed, leaving the ringtone playing over the lock screen.
      canPop: false,
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
            Text(caller,
                style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
            const SizedBox(height: 16),
            CircleAvatar(
              radius: 52,
              backgroundColor: Colors.blueGrey.shade700,
              child: Text(caller.isEmpty ? '?' : caller[0].toUpperCase(),
                  style: const TextStyle(fontSize: 44, color: Colors.white)),
            ),
            const SizedBox(height: 12),
            if (!em.fakeCallAnswered)
              const Text('Incoming call', style: TextStyle(color: Colors.white54))
            else
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.call, color: Colors.green, size: 16),
                const SizedBox(width: 6),
                Text(_fmt(_seconds),
                    style:
                        const TextStyle(color: Colors.green, fontSize: 16)),
              ]),
            const Spacer(),
            if (!em.fakeCallAnswered) ...[
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _actionButton(Icons.alarm, 'Remind Me', () {}),
                _actionButton(Icons.message, 'Message', () {}),
              ]),
              const SizedBox(height: 24),
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
                _roundButton(Icons.call_end, Colors.red, _leave),
                _roundButton(Icons.call, Colors.green, () async {
                  if (_ticking) return;
                  _ticking = true;
                  final rec = app.selectedRecording;
                  await em.answerFakeCall(rec?.filePath);
                  _tick();
                }),
              ]),
            ] else ...[
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _actionButton(Icons.add, 'Add call', () {}),
                _actionButton(Icons.videocam, 'Video call', () {}),
                _actionButton(Icons.bluetooth, 'Bluetooth', () {}),
              ]),
              const SizedBox(height: 20),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _actionButton(Icons.volume_up, 'Speaker', () {}),
                _actionButton(Icons.mic_off, 'Mute', () {}),
                _actionButton(Icons.dialpad, 'Keypad', () {}),
              ]),
              const SizedBox(height: 24),
              // Wrapped in a full-width Row like the incoming-call branch:
              // without it the Column shrinks to its widest child and the
              // whole screen jumps left the instant the call is answered,
              // which instantly breaks the "real dialer" illusion.
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                // Pop only; the PopScope tears down (see the incoming branch).
                _roundButton(Icons.call_end, Colors.red, _leave),
              ]),
            ],
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

  Widget _actionButton(IconData icon, String label, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(
                color: Colors.white12, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ]),
      );
}
