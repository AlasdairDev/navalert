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
            // SOS press & hold
            GestureDetector(
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
                    value: em.holdingSos ? em.holdProgress : 0,
                    strokeWidth: 8,
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
                      app.fakeCallConfig.recordingId = r.recordingId;
                      await app.saveFakeCallConfig();
                      if (!context.mounted) return;
                      final vm = context.read<EmergencyViewModel>();
                      await vm.startFakeCall(
                          callerName: app.fakeCallConfig.callerName);
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
