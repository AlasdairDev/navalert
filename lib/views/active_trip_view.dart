import 'dart:math' as math;

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

    // DO NOT MODIFY LOGIC: vm.phase is driven by the live GPS + adaptive alarm
    // engine (R1–R4). This switch decides which sub-screen shows. You may
    // restyle each sub-widget (_AlarmStage, _Monitoring, etc.), but keep the
    // phase→widget mapping and all seven cases.
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
      // ╔══════════════════════════════════════════════════════════════════╗
      // ║ DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:                 ║
      // ║ HARDWARE BACK-BUTTON GUARD (anti-oversleep, R1).                 ║
      // ║                                                                  ║
      // ║ UI TEAM: this PopScope wrapper is a presentation-critical SAFETY ║
      // ║ guard, demonstrated live to the panel. You may restyle anything  ║
      // ║ inside `child:` — colours, padding, typography, the whole        ║
      // ║ layout. You must NOT remove or unwrap this PopScope, change      ║
      // ║ `canPop`, or edit `onPopInvokedWithResult`. Deleting the wrapper ║
      // ║ lets the Back button silently cancel a live trip, which kills    ║
      // ║ the alarm the rider is asleep trusting.                          ║
      // ╚══════════════════════════════════════════════════════════════════╝
      // The rider must Slide-to-Stop to leave.
      //
      // canPop is now HARD false: the hardware Back button and the edge-swipe
      // can never abandon the trip screen, in any phase. This is safe because
      // PopScope only intercepts SYSTEM back gestures — it does not affect
      // programmatic Navigator.pop(), so Slide-to-Stop and the summary's
      // Done/Close buttons still close this screen exactly as before.
      canPop: false,
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
            // Capped at two lines: at 26 px a long place name wrapped to four
            // or five, and this Column already spends 170 px on the monitoring
            // badge plus the slider and the SOS / Fake Call row. On a short
            // screen the Spacers collapse to zero and the whole column
            // overflows — taking the Slide-to-Stop control off screen, which is
            // the only way to end a trip.
            Text(vm.trip!.destinationLabel,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
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
            // DO NOT MODIFY LOGIC: the anti-oversleep gesture — the only way to
            // end monitoring. Keep onCompleted → stopTrip() + pop(). You may
            // restyle the slider (see _SlideToStop below); do not lower its
            // completion threshold (it guards against a stray-thumb dismiss).
            _SlideToStop(onCompleted: () async {
              await vm.stopTrip();
              if (context.mounted) Navigator.of(context).pop();
            }),
            const SizedBox(height: 14),
            // ╔════════════════════════════════════════════════════════════╗
            // ║ DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:           ║
            // ║ SPAM-TAP DEBOUNCERS for the SOS and Fake Call buttons.     ║
            // ║                                                            ║
            // ║ UI TEAM: `em.sending` and `em.fakeCallActive` are the      ║
            // ║ in-flight (isProcessing) flags. Restyle these buttons all  ║
            // ║ you like — colours, icons, sizes, spacing, the label copy. ║
            // ║ Do NOT replace the `onPressed: <flag> ? null : ...`        ║
            // ║ pattern with a plain handler, and do NOT drop the Builder  ║
            // ║ or its context.watch — that is what re-enables the button  ║
            // ║ when the action finishes. Hard-wiring onPressed lets a     ║
            // ║ panic-tapping rider fire duplicate SOS texts (real cost:   ║
            // ║ their prepaid load) and stack fake-call screens.           ║
            // ╚════════════════════════════════════════════════════════════╝
            // The ViewModel guards (fireSos's `sending` flag, startFakeCall's
            // `fakeCallActive` gate) already stop the work running twice, but an
            // enabled-looking button that silently eats taps reads as "the app
            // is broken" at the exact moment the rider needs it — so the state
            // is now visible, not just enforced.
            Builder(builder: (context) {
              final em = context.watch<EmergencyViewModel>();
              return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: NavAlertColors.danger),
                      onPressed: em.sending
                          ? null
                          : () => context
                              .read<EmergencyViewModel>()
                              .fireSos(tripId: vm.trip!.tripId),
                      icon: const Icon(Icons.warning_amber, size: 18),
                      label: Text(em.sending ? 'Sending…' : 'SOS'),
                    ),
                    const SizedBox(width: 14),
                    ElevatedButton.icon(
                      onPressed: em.fakeCallActive
                          ? null
                          : () async {
                              final em = context.read<EmergencyViewModel>();
                              // Push only if this tap started the call — see the
                              // panic-tap guard in startFakeCall.
                              final started = await em.startFakeCall(
                                  callerName: context
                                      .read<AppViewModel>()
                                      .fakeCallConfig
                                      .callerName);
                              if (started && context.mounted) {
                                Navigator.of(context).push(MaterialPageRoute(
                                    fullscreenDialog: true,
                                    builder: (_) => const FakeCallView()));
                              }
                            },
                      icon: const Icon(Icons.phone_in_talk, size: 18),
                      label: const Text('Fake Call'),
                    ),
                  ]);
            }),
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
      // Figure 28 — Emergency Full-Screen Alert.
      // TODO (UI Team): Stage 3 is [EDIT]-heavy — make it alarming and
      // impossible to sleep through (bold type, pulsing, high contrast).
      // USE THEME: the dark-red background 0xFF3B0A0A is a deliberate "danger"
      // wash; if you retheme, keep Stage 3 unmistakably red/urgent. Do NOT
      // make it easier to dismiss (R1: it must stay a hard-to-dismiss alert).
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
                    // Expanded is load-bearing, not decoration: a Row hands its
                    // non-flex children UNBOUNDED width, so the destination
                    // name laid out on a single line and ran off the card
                    // ("RIGHT OVERFLOWED BY N PIXELS"). Place names are long
                    // enough to do that on an ordinary 360 dp phone — and this
                    // is the alarm screen, which the rider sees every trip.
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(distText,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 16)),
                            Text(vm.trip!.destinationLabel,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: NavAlertColors.textSecondary)),
                          ]),
                    ),
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
class _OvershootPrompt extends StatefulWidget {
  const _OvershootPrompt({required this.vm});
  final TripViewModel vm;

  @override
  State<_OvershootPrompt> createState() => _OvershootPromptState();
}

class _OvershootPromptState extends State<_OvershootPrompt> {
  // DO NOT MODIFY LOGIC: in-flight guard. answerOvershoot(true) writes the
  // overshoot audit row and then ENDS the trip, and both buttons stay on screen
  // for the whole await — so a panic-tapped "Yes" wrote duplicate overshoot
  // events for one trip and ran the end-of-trip teardown twice. Tapping "No"
  // then "Yes" in quick succession could also interleave the two answers.
  bool _answering = false;

  Future<void> _answer(bool missed) async {
    if (_answering) return;
    _answering = true;
    try {
      await widget.vm.answerOvershoot(missed);
    } catch (_) {
      // Re-arm so the rider is never stuck on the prompt with dead buttons.
      if (mounted) _answering = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
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
                        onPressed: () => _answer(false),
                        child: const Text('No')),
                    const SizedBox(width: 14),
                    ElevatedButton(
                        onPressed: () => _answer(true),
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

/// DO NOT MODIFY LOGIC: shared exit for the two end-of-trip summary cards.
///
/// "Close"/"Done" stays on screen for the whole pop transition, so a second tap
/// fired a SECOND Navigator.pop() that ate the route underneath and dropped the
/// rider out of the shell onto a blank stack. Same double-pop class as the
/// fake-call End button. `closeSummary` is idempotent (it only sets the phase),
/// so the guard is purely about the navigation.
class _SummaryCloseButton extends StatefulWidget {
  const _SummaryCloseButton({required this.vm, required this.child, this.filled = false});
  final TripViewModel vm;
  final Widget child;
  final bool filled;

  @override
  State<_SummaryCloseButton> createState() => _SummaryCloseButtonState();
}

class _SummaryCloseButtonState extends State<_SummaryCloseButton> {
  bool _closing = false;

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    try {
      await widget.vm.closeSummary();
    } catch (_) {
      // Never strand the rider on the summary: leaving is the whole job here.
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => widget.filled
      ? ElevatedButton(onPressed: _close, child: widget.child)
      : OutlinedButton(onPressed: _close, child: widget.child);
}

/// Panic-tap guard for the reroute hand-off. Each tap fires an EXTERNAL intent,
/// so five taps queued five Google Maps launches — the rider returns to a stack
/// of map windows over the app they were trying to get back to. The button is
/// re-armed once the launch settles, because a failed hand-off must stay
/// retryable (the ViewModel falls back to a clipboard copy).
class _RerouteButton extends StatefulWidget {
  const _RerouteButton({required this.vm});
  final TripViewModel vm;

  @override
  State<_RerouteButton> createState() => _RerouteButtonState();
}

class _RerouteButtonState extends State<_RerouteButton> {
  bool _launching = false;

  Future<void> _open() async {
    if (_launching) return;
    setState(() => _launching = true);
    try {
      await widget.vm.openRerouteInGoogleMaps();
    } catch (_) {
      // The ViewModel already reports failure through vm.error.
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  @override
  Widget build(BuildContext context) => ElevatedButton.icon(
        onPressed: _launching ? null : _open,
        icon: const Icon(Icons.map, size: 18),
        label: const Text('Open in GMaps'),
      );
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
                    _SummaryCloseButton(vm: vm, child: const Text('Close')),
                    const SizedBox(width: 14),
                    _RerouteButton(vm: vm),
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
            _SummaryCloseButton(
                vm: vm, filled: true, child: const Text('Done')),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Slide-to-stop / slide-to-dismiss control
//
// DO NOT MODIFY LOGIC: the gesture math (absolute localPosition tracking, the
// maxDrag/height arithmetic, the 60% completion threshold) is load-bearing —
// it's the anti-oversleep dismissal, the only way off the alarm screen while
// PopScope blocks Back. It was rebuilt in Batch 2 to fix a "knob gets stuck"
// bug; do not revert it to delta-accumulation or raise the threshold.
// TODO (UI Team): the pill's LOOK is [EDIT] — colour/alpha, height, border,
// corner radius, the knob icon, and the label text. Restyle the Container +
// knob; leave the drag handlers alone.
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
      // Never negative: if the UI team ever pads this pill down below the 54 px
      // knob, `width - height` goes negative and `clamp(0.0, maxDrag)` throws
      // ArgumentError ("max cannot be less than min") on the first drag — a
      // crash on the one control that ends a trip.
      // ╔══════════════════════════════════════════════════════════════════╗
      // ║ DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:                 ║
      // ║ SLIDER WIDTH MATH — math.max(0.0, width - height).               ║
      // ║                                                                  ║
      // ║ UI TEAM: the `math.max(0.0, ...)` floor is not defensive         ║
      // ║ decoration. If you pad this pill narrower than the 54 px knob,   ║
      // ║ `width - height` goes NEGATIVE and the `.clamp(0.0, maxDrag)`    ║
      // ║ below throws ArgumentError ("max cannot be less than min") on    ║
      // ║ the first drag — a hard crash, on stage, on the ONE control that ║
      // ║ ends a trip. Restyle the pill's height, colour, radius and knob  ║
      // ║ freely; never remove this floor or the `maxDrag > 0` check in    ║
      // ║ the drag-end handler.                                            ║
      // ╚══════════════════════════════════════════════════════════════════╝
      final maxDrag = math.max(0.0, width - height);
      return Center(
        // The WHOLE pill accepts the drag, not just the knob. A 48 px knob is
        // an unrealistic target for a rider on a moving jeepney, and claiming
        // horizontal drags across the full pill also wins the gesture arena
        // against the commute-guide sheet below, which competes for vertical
        // drags — otherwise a slightly diagonal swipe does nothing at all and
        // the rider is stuck on this screen (PopScope blocks Back by design).
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Track the finger's ABSOLUTE position within the pill, not an
          // accumulated delta. Delta-accumulation desyncs when the horizontal
          // drag recognizer wins the gesture arena a few frames late (the early
          // deltas are lost), which made the knob feel stuck / not reach the
          // end. localPosition is relative to this detector, so the knob
          // follows the finger exactly. Threshold relaxed to 60%.
          onHorizontalDragUpdate: (d) => setState(() =>
              _drag = (d.localPosition.dx - height / 2).clamp(0.0, maxDrag)),
          // A drag the system takes away from us (notification shade pulled
          // down, an incoming call overlay, the pointer cancelled) does not
          // always deliver an end event. Without this the knob stayed frozen
          // mid-track, which reads as "the control is broken" on the one gesture
          // that ends a trip — and Back is blocked here by design.
          onHorizontalDragCancel: () {
            if (_done || _drag == 0) return;
            setState(() => _drag = 0);
          },
          onHorizontalDragEnd: (_) async {
            // `maxDrag > 0` is NOT redundant with the clamp above. Once maxDrag
            // is floored at zero, the threshold `_drag >= maxDrag * 0.6` reads
            // `0 >= 0` — TRUE — so a degenerate pill width would fire the stop
            // on the faintest sideways touch, silently cancelling the alarm the
            // rider is relying on. That is worse than the crash it replaces, so
            // no travel distance must mean no completion.
            if (maxDrag > 0 && _drag >= maxDrag * 0.6 && !_done) {
              _done = true;
              setState(() => _drag = maxDrag);
              // DO NOT MODIFY LOGIC: if the action fails, the control MUST
              // become usable again. _done was previously latched before the
              // await with no catch, so a single failure inside stopTrip (an
              // unguarded plugin call was enough) left the slider permanently
              // dead — and PopScope blocks Back on this screen, so the rider
              // was trapped in a trip they could not end.
              final messenger = ScaffoldMessenger.of(context);
              try {
                await widget.onCompleted();
              } catch (_) {
                if (!mounted) return;
                _done = false;
                setState(() => _drag = 0);
                messenger.showSnackBar(const SnackBar(
                    content: Text('Could not stop the trip — please try '
                        'again.')));
              }
            } else {
              setState(() => _drag = 0);
            }
          },
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
                child: Container(
                  width: height - 6,
                  height: height - 6,
                  decoration: BoxDecoration(
                      color: widget.color, shape: BoxShape.circle),
                  child:
                      const Icon(Icons.chevron_right, color: Colors.white),
                ),
              ),
            ]),
          ),
        ),
      );
    });
  }
}
