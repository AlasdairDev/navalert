import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/emergency_viewmodel.dart';
import 'fake_call_view.dart';

/// Figure 32 — Emergency screen: press-and-hold SOS (3 s) and the
/// fake-call recording list.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] SOS GestureDetector onTapDown/Up beginSosHold/cancelSosHold
///         (the 3-second hold = accidental-trigger guard, R8) · progress
///         ring value (em.holdProgress) · "Call 911" onPressed · recording
///         ListTile onTap → startFakeCall → FakeCallView · load-warning
///         dismiss. Keep SOS red and obviously the biggest tap target.
///  [EDIT] SOS button size/glow, "Press & Hold to Activate" copy, hold-hint
///         text, "Activate Fake Call" heading, recording row styling,
///         load-warning card look, Call 911 button style.
///  [WANT] countdown animation during hold, haptic on hold, contact avatars.
class EmergencyView extends StatelessWidget {
  const EmergencyView({super.key});

  @override
  Widget build(BuildContext context) {
    final em = context.watch<EmergencyViewModel>();
    final app = context.watch<AppViewModel>();

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            // Insufficient Load Warning (Activity Diagram / app_state):
            // SOS uses Native Android SMS and needs prepaid load.
            if (app.showSosLowLoadWarning)
              Card(
                color: NavAlertColors.surface,
                child: ListTile(
                  leading: const Icon(Icons.sim_card_alert,
                      color: NavAlertColors.warning),
                  title: const Text('Insufficient load warning',
                      style: TextStyle(fontSize: 13)),
                  subtitle: const Text(
                      'SOS sends a native SMS — keep sufficient prepaid load '
                      'so alerts can be delivered without internet.',
                      style: TextStyle(
                          fontSize: 11, color: NavAlertColors.textSecondary)),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => context
                        .read<AppViewModel>()
                        .dismissSosLowLoadWarning(),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            // SOS press & hold (UC-7). TODO (UI Team): the button's size,
            // glow, ring, and typography are all restyleable — this is a
            // high-value screen to make feel urgent and unmistakable.
            GestureDetector(
              // DO NOT MODIFY LOGIC: the 3-second press-and-hold guard against
              // accidental SOS. Keep beginSosHold/cancelSosHold on down/up/
              // cancel and the onFired → _showResult callback. `holdProgress`
              // (0→1) drives the ring below — keep reading it.
              onTapDown: (_) => context.read<EmergencyViewModel>().beginSosHold(
                  onFired: () => _showResult(context)),
              onTapUp: (_) =>
                  context.read<EmergencyViewModel>().cancelSosHold(),
              onTapCancel: () =>
                  context.read<EmergencyViewModel>().cancelSosHold(),
              child: Stack(alignment: Alignment.center, children: [
                SizedBox(
                  width: 190,
                  height: 190,
                  child: CircularProgressIndicator(
                    // DO NOT MODIFY LOGIC: `value` shows hold progress. Restyle
                    // stroke/colors, but keep it bound to em.holdProgress.
                    value: em.holdingSos ? em.holdProgress : 0,
                    strokeWidth: 8,
                    // USE THEME: white ring on danger red is deliberate; if you
                    // change it keep the SOS unmistakably red (NavAlertColors.
                    // danger carries the "emergency" meaning — don't recolor it).
                    color: Colors.white,
                    backgroundColor:
                        NavAlertColors.danger.withValues(alpha: 0.3),
                  ),
                ),
                Container(
                  width: 170,
                  height: 170,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: NavAlertColors.danger,
                    boxShadow: [
                      BoxShadow(
                          color:
                              NavAlertColors.danger.withValues(alpha: 0.55),
                          blurRadius: 44),
                    ],
                  ),
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(em.sending ? 'SENDING…' : 'SOS',
                            style: const TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w900,
                                color: Colors.white)),
                        const Text('Press & Hold to Activate',
                            style: TextStyle(
                                fontSize: 11, color: Colors.white70)),
                      ]),
                ),
              ]),
            ),
            const SizedBox(height: 10),
            Text(
                'Hold for 3 seconds to notify ${app.contacts.isEmpty ? 'your' : app.contacts.length} contact${app.contacts.length == 1 ? '' : 's'} via SMS',
                style: const TextStyle(
                    fontSize: 12, color: NavAlertColors.textSecondary)),
            if (em.statusMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(em.statusMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: NavAlertColors.warning, fontSize: 12)),
              ),
            TextButton.icon(
              onPressed: () => context.read<EmergencyViewModel>().call911(),
              icon: const Icon(Icons.call, color: NavAlertColors.danger),
              label: const Text('Call 911',
                  style: TextStyle(color: NavAlertColors.danger)),
            ),
            const Divider(height: 30),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Activate Fake Call',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 8),
            ...app.recordings.map((r) => Card(
                  child: ListTile(
                    title: Text(r.title),
                    // Figure 32: presets read "Built-in recording"; a rider's
                    // own clips are dated so several "Standard recording N"
                    // entries can be told apart at a glance.
                    subtitle: Text(
                        r.isPreset
                            ? 'Built-in recording'
                            : _shortDate(r.recordedAt),
                        style: const TextStyle(
                            fontSize: 11,
                            color: NavAlertColors.textSecondary)),
                    trailing: const Icon(Icons.phone_callback,
                        color: NavAlertColors.accent),
                    onTap: () async {
                      // Bug fix: the caller name must follow the CHOSEN
                      // recording, otherwise picking "Dad call recording" still
                      // showed "Mom". Derive the display name from the recording
                      // title ("Dad call recording" → "Dad") and persist it so
                      // the call screen and lock-screen notification agree.
                      final caller = r.title.split(' ').first;
                      app.fakeCallConfig.recordingId = r.recordingId;
                      app.fakeCallConfig.callerName = caller;
                      // DO NOT MODIFY LOGIC: persisting the choice must never
                      // gate the call itself. This write used to be awaited
                      // unguarded, so a storage failure threw here and the
                      // fake call NEVER STARTED — the escape feature dying at
                      // exactly the moment the rider needs it. Remembering the
                      // selection is a convenience; launching the call is the
                      // safety feature.
                      try {
                        await app.saveFakeCallConfig();
                      } catch (_) {/* not persisted — still place the call */}
                      if (!context.mounted) return;
                      final vm = context.read<EmergencyViewModel>();
                      await vm.startFakeCall(callerName: caller);
                      if (context.mounted) {
                        Navigator.of(context).push(MaterialPageRoute(
                            fullscreenDialog: true,
                            builder: (_) => const FakeCallView()));
                      }
                    },
                  ),
                )),
          ]),
        ),
      ),
    );
  }

  void _showResult(BuildContext context) {
    final msg = context.read<EmergencyViewModel>().statusMessage;
    if (msg != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// dd/MM/yy — the compact form shown under custom recordings in Figure 32.
  static String _shortDate(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${two(d.year % 100)}';
  }
}
