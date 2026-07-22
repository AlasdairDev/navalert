import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/emergency_viewmodel.dart';
import '../viewmodels/trip_viewmodel.dart';
import 'commute_guide_sheet.dart';
import 'fake_call_view.dart';

/// Figures 24–29 — Active Trip (Monitoring Mode), the three alarm
/// stages, and Overshoot Detected.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] the phase switch (vm.phase → which sub-view shows) · _SlideToStop
///         onCompleted (stop/dismiss — the anti-oversleep gesture) · Snooze/
///         Dismiss onPressed · SOS & Fake Call onPressed · overshoot Yes/No
///         + "Open in GMaps" (vm.openRerouteInGoogleMaps) · PopScope guard.
///         Stage 3 MUST stay a hard-to-dismiss full-screen alarm (R1).
///  [EDIT] all copy ("En Route", "Get some rest…", "WAKE UP", "Approaching
///         Stop"), the Monitoring moon badge, colors per stage (Stage 1 calm →
///         Stage 3 red), distance/speed/ETA text, checklist items, slider look.
///  [WANT] pulsing/animated Stage-3 background, progress ring to destination,
///         haptic-synced visuals, richer arrived celebration.
class ActiveTripView extends StatelessWidget {
  const ActiveTripView({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TripViewModel>();
    final trip = vm.trip;
    if (trip == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final body = switch (vm.phase) {
      TripPhase.alarmStage1 => _AlarmStage(vm: vm, stage: 1),
      TripPhase.alarmStage2 => _AlarmStage(vm: vm, stage: 2),
      TripPhase.alarmStage3 => _AlarmStage(vm: vm, stage: 3),
      TripPhase.overshootPrompt => _OvershootPrompt(vm: vm),
      TripPhase.overshootConfirmed => _OvershootConfirmed(vm: vm),
      TripPhase.arrived => _Arrived(vm: vm),
      _ => _Monitoring(vm: vm),
    };

    return PopScope(
      canPop: vm.phase == TripPhase.ended,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Slide to stop the trip before leaving.')));
      },
      // The commute-guide sheet rides ONLY on the monitoring screen. During an
      // alarm stage or the overshoot prompt the screen must be the alert and
      // nothing else — a draggable panel over a Stage 3 wake-up would be both
      // a distraction and a mis-tap risk.
      child: Scaffold(
        body: vm.phase == TripPhase.monitoring && !vm.guide.isEmpty
            ? Stack(children: [
                // Reserve the collapsed sheet's height so it can never sit on
                // top of the SOS / Fake Call buttons.
                Padding(
                  padding: EdgeInsets.only(
                      bottom: CommuteGuideSheet.collapsedHeight(context)),
                  child: body,
                ),
                const CommuteGuideSheet(),
              ])
            : body,
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Figure 24 — Monitoring Mode
// ---------------------------------------------------------------------
class _Monitoring extends StatelessWidget {
  const _Monitoring({required this.vm});
  final TripViewModel vm;

  @override
  Widget build(BuildContext context) {
    final km = vm.distanceM / 1000;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF3A1F63), NavAlertColors.background],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const SizedBox(height: 24),
            const Text('En Route',
                style: TextStyle(color: NavAlertColors.textSecondary)),
            Text(vm.trip!.destinationLabel,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w700)),
            const Text('Get some rest. We got you.',
                style: TextStyle(
                    color: NavAlertColors.textSecondary,
                    fontStyle: FontStyle.italic)),
            const Spacer(),
            Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: NavAlertColors.surface,
                boxShadow: [
                  BoxShadow(
                      color: NavAlertColors.primary.withValues(alpha: 0.45),
                      blurRadius: 40),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.nightlight_round,
                      size: 54, color: NavAlertColors.accent),
                  SizedBox(height: 6),
                  Text('Monitoring'),
                  Text('Active',
                      style: TextStyle(
                          fontSize: 11, color: NavAlertColors.success)),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
              decoration: BoxDecoration(
                color: NavAlertColors.surface,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                  km >= 1
                      ? '${km.toStringAsFixed(1)} km away'
                      : '${vm.distanceM.toStringAsFixed(0)} m away',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700)),
            ),
            Text(
                'speed ${vm.speedKmh.toStringAsFixed(0)} km/h'
                '${vm.etaMinutes == null ? '' : '  ·  ETA ${vm.etaMinutes!.round()} min'}',
                style: const TextStyle(
                    fontSize: 12, color: NavAlertColors.textSecondary)),
            // UC-1 Exception 2 — "Signal Lost" fallback alarm.
            if (vm.signalLostAlarm)
              Card(
                color: const Color(0xFF4A2A00),
                child: ListTile(
                  leading: const Icon(Icons.gps_off,
                      color: NavAlertColors.warning),
                  title: const Text('Signal Lost',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text(
                      'GPS has been unavailable — stay alert for your stop.',
                      style: TextStyle(fontSize: 11)),
                  trailing: ElevatedButton(
                    onPressed: vm.dismissSignalLostAlarm,
                    child: const Text('Dismiss'),
                  ),
                ),
              )
            else if (vm.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(vm.error!,
                    style: const TextStyle(
                        color: NavAlertColors.warning, fontSize: 12)),
              ),
            const Spacer(),
            _SlideToStop(onCompleted: () async {
              await vm.stopTrip();
              if (context.mounted) Navigator.of(context).pop();
            }),
            const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: NavAlertColors.danger),
                onPressed: () =>
                    context.read<EmergencyViewModel>().fireSos(
                        tripId: vm.trip!.tripId),
                icon: const Icon(Icons.warning_amber, size: 18),
                label: const Text('SOS'),
              ),
              const SizedBox(width: 14),
              ElevatedButton.icon(
                onPressed: () async {
                  final em = context.read<EmergencyViewModel>();
                  await em.startFakeCall(
                      callerName:
                          context.read<AppViewModel>().fakeCallConfig.callerName);
                  if (context.mounted) {
                    Navigator.of(context).push(MaterialPageRoute(
                        fullscreenDialog: true,
                        builder: (_) => const FakeCallView()));
                  }
                },
                icon: const Icon(Icons.phone_in_talk, size: 18),
                label: const Text('Fake Call'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Figures 26–28 — Alarm Stages 1–3
// ---------------------------------------------------------------------
class _AlarmStage extends StatelessWidget {
  const _AlarmStage({required this.vm, required this.stage});
  final TripViewModel vm;
  final int stage;

  @override
  Widget build(BuildContext context) {
    final km = vm.distanceM / 1000;
    final distText = km >= 1
        ? '${km.toStringAsFixed(1)} km away'
        : '${vm.distanceM.toStringAsFixed(0)} m away';

    if (stage == 3) {
      // Figure 28 — Emergency Full-Screen Alert
      return Container(
        color: const Color(0xFF3B0A0A),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(children: [
              const Spacer(),
              const Text('Alarm Stage 3',
                  style: TextStyle(
                      fontStyle: FontStyle.italic, color: Colors.white70)),
              const SizedBox(height: 10),
              const Text('WAKE UP',
                  style: TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.w900,
                      color: NavAlertColors.danger,
                      letterSpacing: 2)),
              const Text('YOU MIGHT MISS YOUR STOP.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 18,
                      fontStyle: FontStyle.italic,
                      color: Colors.white)),
              const SizedBox(height: 10),
              Text(distText, style: const TextStyle(color: Colors.white70)),
              const Spacer(),
              _SlideToStop(
                label: 'Slide to dismiss',
                color: NavAlertColors.danger,
                onCompleted: vm.dismissAlarm,
              ),
              const SizedBox(height: 30),
            ]),
          ),
        ),
      );
    }

    final (title, message) = stage == 1
        ? ('Approaching Stop', 'Get ready to go down.')
        : ('Get Ready', 'You are near your destination.');

    return Container(
      color: NavAlertColors.background,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const Spacer(),
            Text('Alarm Stage $stage',
                style: const TextStyle(
                    fontStyle: FontStyle.italic,
                    color: NavAlertColors.textSecondary)),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(children: [
                  Row(children: [
                    const Icon(Icons.location_on,
                        color: NavAlertColors.accent),
                    const SizedBox(width: 8),
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(distText,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 16)),
                          Text(vm.trip!.destinationLabel,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: NavAlertColors.textSecondary)),
                        ]),
                  ]),
                  const Divider(height: 24),
                  Text(title,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700)),
                  Text(message,
                      style: const TextStyle(
                          color: NavAlertColors.textSecondary)),
                  const SizedBox(height: 16),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    ElevatedButton(
                        onPressed: vm.snoozeAlarm,
                        child: const Text('Snooze')),
                    const SizedBox(width: 12),
                    ElevatedButton(
                        onPressed: vm.dismissAlarm,
                        child: const Text('Dismiss')),
                  ]),
                ]),
              ),
            ),
            const SizedBox(height: 20),
            // Same list the ViewModel logs to alarm_events.checklist_items,
            // so the screen and the trip record can never drift apart.
            if (stage == 1)
              ...TripViewModel.alarmChecklist.map(_check),
            const Spacer(),
          ]),
        ),
      ),
    );
  }

  Widget _check(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.check_circle_outline,
              color: Color(0xFF4DD0E1), size: 20),
          const SizedBox(width: 8),
          Text(text),
        ]),
      );
}

// ---------------------------------------------------------------------
// Figure 29 — Overshoot Detected
// ---------------------------------------------------------------------
class _OvershootPrompt extends StatelessWidget {
  const _OvershootPrompt({required this.vm});
  final TripViewModel vm;

  @override
  Widget build(BuildContext context) {
    final m = vm.overshotM;
    return Container(
      color: NavAlertColors.background,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Overshoot Detected',
                      style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: NavAlertColors.textSecondary)),
                  const SizedBox(height: 12),
                  const Text('Did you miss your stop?',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                      'You might have passed your destination by '
                      '${m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} kilometers' : '${m.toStringAsFixed(0)} meters'}.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: NavAlertColors.textSecondary)),
                  const SizedBox(height: 18),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    ElevatedButton(
                        onPressed: () => vm.answerOvershoot(false),
                        child: const Text('No')),
                    const SizedBox(width: 14),
                    ElevatedButton(
                        onPressed: () => vm.answerOvershoot(true),
                        child: const Text('Yes')),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OvershootConfirmed extends StatelessWidget {
  const _OvershootConfirmed({required this.vm});
  final TripViewModel vm;

  @override
  Widget build(BuildContext context) {
    final m = vm.overshotM;
    return Container(
      color: NavAlertColors.background,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.fmd_bad,
                      size: 48, color: NavAlertColors.warning),
                  const SizedBox(height: 10),
                  const Text('You missed your stop.',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                      'You passed your destination by '
                      '${m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} kilometer(s)' : '${m.toStringAsFixed(0)} meters'}.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: NavAlertColors.textSecondary)),
                  const SizedBox(height: 18),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    OutlinedButton(
                        onPressed: () async {
                          await vm.closeSummary();
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        child: const Text('Close')),
                    const SizedBox(width: 14),
                    ElevatedButton.icon(
                        onPressed: vm.openRerouteInGoogleMaps,
                        icon: const Icon(Icons.map, size: 18),
                        label: const Text('Open in GMaps')),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Arrived extends StatelessWidget {
  const _Arrived({required this.vm});
  final TripViewModel vm;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: NavAlertColors.background,
      child: SafeArea(
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.celebration,
                size: 72, color: NavAlertColors.success),
            const SizedBox(height: 14),
            const Text('You have arrived!',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
            Text(vm.trip!.destinationLabel,
                style: const TextStyle(color: NavAlertColors.textSecondary)),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () async {
                await vm.closeSummary();
                if (context.mounted) Navigator.of(context).pop();
              },
              child: const Text('Done'),
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Slide-to-stop / slide-to-dismiss control
// ---------------------------------------------------------------------
class _SlideToStop extends StatefulWidget {
  const _SlideToStop({
    required this.onCompleted,
    this.label = 'Slide to Stop',
    this.color = NavAlertColors.primaryButton,
  });

  final Future<void> Function() onCompleted;
  final String label;
  final Color color;

  @override
  State<_SlideToStop> createState() => _SlideToStopState();
}

class _SlideToStopState extends State<_SlideToStop> {
  double _drag = 0;
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    const height = 54.0;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth.clamp(0.0, 320.0);
      final maxDrag = width - height;
      return Center(
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(height / 2),
            border: Border.all(color: widget.color),
          ),
          child: Stack(children: [
            Center(
                child: Text(widget.label,
                    style: const TextStyle(fontWeight: FontWeight.w600))),
            Positioned(
              left: _drag,
              top: 3,
              child: GestureDetector(
                onHorizontalDragUpdate: (d) => setState(() =>
                    _drag = (_drag + d.delta.dx).clamp(0.0, maxDrag)),
                onHorizontalDragEnd: (_) async {
                  if (_drag >= maxDrag * 0.9 && !_done) {
                    _done = true;
                    await widget.onCompleted();
                  } else {
                    setState(() => _drag = 0);
                  }
                },
                child: Container(
                  width: height - 6,
                  height: height - 6,
                  decoration: BoxDecoration(
                      color: widget.color, shape: BoxShape.circle),
                  child:
                      const Icon(Icons.chevron_right, color: Colors.white),
                ),
              ),
            ),
          ]),
        ),
      );
    });
  }
}
