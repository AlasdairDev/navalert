import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/emergency_viewmodel.dart';
import '../viewmodels/home_viewmodel.dart';
import '../viewmodels/trip_viewmodel.dart';
import 'commute_guide_sheet.dart';
import 'commute_sheet_layout.dart';
import 'fake_call_view.dart';
import 'trip_map.dart';

/// Figures 24–29 — Active Trip (Monitoring Mode), the three alarm
/// stages, and Overshoot Detected.
///
/// Monitoring is CONTEXTUAL — see [_Monitoring]. With the destination alarm
/// armed it is Figure 24 as the mockups draw it; with the alarm off the commute
/// guide takes the screen and the monitoring readouts shrink to a strip, because
/// a rider who declined the alarm is using NavAlert as a navigation guide and
/// the moon badge would be advertising a service that is switched off.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] the phase switch (vm.phase → which sub-view shows) · _SlideToStop
///         onCompleted (stop/dismiss — the anti-oversleep gesture) · Snooze/
///         Dismiss onPressed · SOS & Fake Call onPressed · overshoot Yes/No
///         + "Open in GMaps" (vm.openRerouteInGoogleMaps) · PopScope guard ·
///         the alarm arm/disarm chip. Stage 3 MUST stay a hard-to-dismiss
///         full-screen alarm (R1), and the back arrow must stay OFF every
///         alarm/overshoot phase — monitoring only.
///  [EDIT] all copy ("En Route", "Get some rest…", "WAKE UP", "Approaching
///         Stop"), the Monitoring moon badge, colors per stage (Stage 1 calm →
///         Stage 3 red), distance/speed/ETA text, checklist items, slider look,
///         the guide-first header and readout strip.
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
      //
      // And only when the alarm is ARMED. With it off, _Monitoring switches to
      // its guide-first layout and renders the very same guide inline, filling
      // the body — stacking the draggable sheet as well would put the guide on
      // screen twice, the second copy sitting over the controls.
      child: Scaffold(
        body: vm.phase == TripPhase.monitoring &&
                !vm.guide.isEmpty &&
                trip.alarmEnabled
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
/// Monitoring has TWO layouts, chosen by whether the destination alarm is
/// armed. The phase→widget mapping in ActiveTripView is untouched: that switch
/// still resolves the monitoring phase to this one widget, and the choice
/// happens inside it.
///
///  * alarm ON  — Figure 24 exactly as the mockups draw it (Pages 13/20/21/22):
///    En Route, the destination, "Get some rest. We got you.", the moon badge,
///    the distance plate, Slide to Stop, SOS / Fake Call. The rider has handed
///    the trip over and is expected to sleep, so the reassurance that something
///    is watching IS the screen.
///  * alarm OFF — guide-first. Nothing is watching for them, so the moon badge
///    would be claiming a service that is switched off, and the steps are the
///    only reason they are here. The guide expands to fill the screen and the
///    monitoring readouts drop to a single strip above the controls.
///
/// No mockup draws the alarm-off case; the mockups only cover the alarm-on
/// screen, which is why that path is left pixel-faithful to them.
class _Monitoring extends StatelessWidget {
  const _Monitoring({required this.vm});
  final TripViewModel vm;

  @override
  Widget build(BuildContext context) => vm.guide.isEmpty ||
          vm.trip!.alarmEnabled
      ? _alarmFirst(context)
      : _guideFirst(context);

  /// Shared night-commute wash behind both layouts.
  static const _wash = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFF3A1F63), NavAlertColors.background],
    ),
  );

  // The distance / speed / ETA strings now live in [_MonitoringText], because
  // the guide-first layout is its own widget and can no longer reach an
  // instance getter here.

  // ── Alarm ON — Figure 24, unchanged ────────────────────────────────────
  Widget _alarmFirst(BuildContext context) {
    final km = vm.distanceM / 1000;
    return Container(
      decoration: _wash,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(children: [
            // The mockups have no back arrow because they draw this screen
            // inside the shell, with the bottom navigation still reachable.
            // This route covers the shell instead, so the arrow is what
            // restores that same freedom to leave.
            const Align(
                alignment: Alignment.centerLeft, child: _BackToShellButton()),
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
            const SizedBox(height: 12),
            _AlarmToggleChip(vm: vm),
            const SizedBox(height: 12),
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
                      'GPS has been unavailable - stay alert for your stop.',
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
            _EmergencyActionsRow(vm: vm),
          ]),
        ),
      ),
    );
  }

  // ── Alarm OFF — guide-first ────────────────────────────────────────────
  // The steps used to BE the screen: an opaque list on the gradient wash. That
  // answered "what do I do next" and nothing else — a rider following
  // turn-by-turn directions could read the instruction but had no way to see
  // where they actually were, which is the one question a navigation tool has
  // to answer. The guide now floats over a live map instead. See
  // [_GuideFirstMonitor].
  Widget _guideFirst(BuildContext context) => _GuideFirstMonitor(vm: vm);
}

// ---------------------------------------------------------------------
// Guide-first monitoring — the commute guide over a live, tracking map
// ---------------------------------------------------------------------
/// Three layers, bottom to top:
///
///  1. [TripMapView] — full-bleed map, camera following the rider.
///  2. a transparent Column: header plate, the sheet's region, footer plate.
///  3. the guide itself, a `DraggableScrollableSheet` inside that region.
///
/// The footer is a SIBLING BELOW the sheet's region rather than a layer over
/// it, which is the whole reason this shape was chosen: the sheet is then
/// structurally incapable of reaching the SOS / Fake Call / Slide-to-Stop
/// controls, however far it is dragged. That is a stronger guarantee than the
/// height arithmetic it replaces on this path — and the arithmetic itself is
/// untouched and still live for the alarm-ON sheet.
///
/// Every element keeps the copy, colours, fonts and order it had as a plain
/// column; only the layering is new. The two additions are the background
/// plates behind the header and footer, without which purple-on-white text over
/// OSM tiles is unreadable — the same device HomeView's header already uses.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] the footer staying OUTSIDE the sheet · the obscured-height notifier
///         feeding the camera · _SlideToStop / _EmergencyActionsRow /
///         _AlarmToggleChip wiring, all unchanged.
///  [EDIT] plate colours and alpha, corner radii, the header's arrangement,
///         the sheet's resting height (see CommuteSheetLayout).
///  [WANT] collapse the header to a single line when the sheet is dragged up,
///         a "next step in 200 m" callout pinned over the map.
class _GuideFirstMonitor extends StatefulWidget {
  const _GuideFirstMonitor({required this.vm});
  final TripViewModel vm;

  @override
  State<_GuideFirstMonitor> createState() => _GuideFirstMonitorState();
}

class _GuideFirstMonitorState extends State<_GuideFirstMonitor> {
  /// Measures the safety footer. Its height is not a constant: the "Signal
  /// Lost" card adds ~90 dp to it mid-trip, and the sheet's budget has to
  /// account for that or the guide would push down over the map.
  final _footerKey = GlobalKey();

  /// Logical pixels of map hidden at the bottom (sheet + footer). Drives the
  /// camera offset so the rider stays centred in what is actually visible.
  /// A notifier, not setState: this changes on every frame of a sheet drag, and
  /// rebuilding the map subtree that often would thrash the tile layer.
  final _obscured = ValueNotifier<double>(0);

  double _footerHeight = 0;

  /// The footer height the obscured-height notifier was last seeded for. See
  /// the seed guard in [_sheetRegion].
  double? _seededFooter;

  @override
  void dispose() {
    _obscured.dispose();
    super.dispose();
  }

  void _measureFooter() {
    final box = _footerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    // The epsilon is what stops this being an infinite setState loop: a
    // re-measure that reports the same height must not schedule another frame.
    if ((box.size.height - _footerHeight).abs() < 0.5) return;
    setState(() => _footerHeight = box.size.height);
  }

  /// DO NOT MODIFY LOGIC: deferred to after the frame, deliberately.
  /// `DraggableScrollableNotification` is dispatched from inside layout, and
  /// writing the notifier there rebuilds the recenter button mid-build —
  /// "setState() or markNeedsBuild() called during build". One frame of latency
  /// is irrelevant; the camera move is debounced downstream anyway.
  void _setObscured(double v) {
    if ((v - _obscured.value).abs() < 0.5) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (v - _obscured.value).abs() >= 0.5) _obscured.value = v;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Guarded by the epsilon in _measureFooter, so this settles after one extra
    // frame instead of looping.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measureFooter();
    });

    final vm = widget.vm;
    final trip = vm.trip!;
    final screenH = MediaQuery.sizeOf(context).height;
    // `read`, not `watch`: this widget already rebuilds on every GPS tick via
    // the TripViewModel above it, and the planned path does not change during a
    // trip — subscribing would only add rebuilds.
    final routePath = context.read<HomeViewModel>().routePath;
    final rider = vm.currentLat != null && vm.currentLng != null
        ? LatLng(vm.currentLat!, vm.currentLng!)
        : null;

    return Stack(children: [
      Positioned.fill(
        child: TripMapView(
          origin: LatLng(trip.originLat, trip.originLng),
          destination: LatLng(trip.destinationLat, trip.destinationLng),
          rider: rider,
          routePath: routePath,
          obscuredBottom: _obscured,
        ),
      ),
      // Positioned.fill, not a bare Column: a non-positioned Stack child is
      // laid out with LOOSE constraints, and this Column's Expanded needs a
      // bounded height to divide. Being explicit also stops the overlay
      // silently collapsing to its children's intrinsic height if the Stack's
      // fit is ever changed.
      Positioned.fill(
        child: Column(children: [
          _header(context, vm),
          // Transparent — the map shows through here, and the sheet hangs from
          // this region's bottom edge.
          Expanded(child: _sheetRegion(context, screenH)),
          KeyedSubtree(key: _footerKey, child: _footer(context, vm)),
        ]),
      ),
    ]);
  }

  // ── The guide, floating ────────────────────────────────────────────────
  Widget _sheetRegion(BuildContext context, double screenH) =>
      LayoutBuilder(builder: (context, constraints) {
        final region = constraints.maxHeight;
        // Held back one frame until the footer has been measured. Rendering the
        // sheet against a footer height of zero would open it at the wrong
        // resting height, and initialChildSize is only honoured on first build
        // — the sheet would stay wrong for the rest of the trip.
        if (_footerHeight <= 0) return const SizedBox.shrink();

        final f = CommuteSheetLayout.resolve(
          screenHeight: screenH,
          regionHeight: region,
          footerHeight: _footerHeight,
        );
        // DO NOT MODIFY LOGIC: seeded ONCE per footer height, not on every
        // build. This method re-runs on every GPS tick, and an unconditional
        // seed would slam the obscured height back to the RESTING value each
        // time — so a rider who dragged the guide open would watch the camera
        // offset snap back a second later, every second. Re-seeding when the
        // footer changes is correct and necessary: that is exactly when the
        // sheet is re-keyed below and returns to its resting height.
        if (_seededFooter != _footerHeight) {
          _seededFooter = _footerHeight;
          _setObscured(f.initial * region + _footerHeight);
        }

        return NotificationListener<DraggableScrollableNotification>(
          onNotification: (n) {
            _setObscured(n.extent * region + _footerHeight);
            // False: this is an observation, not a consumption — anything else
            // listening for sheet extents still gets to see it.
            return false;
          },
          child: DraggableScrollableSheet(
            // Re-keyed when the footer changes height (the Signal Lost card
            // arriving or clearing), because initialChildSize is read once at
            // construction. Without this the sheet keeps a resting height
            // computed for a footer that no longer exists, and starts covering
            // the map half it was sized to protect.
            key: ValueKey(_footerHeight.round()),
            initialChildSize: f.initial,
            minChildSize: f.min,
            maxChildSize: f.max,
            // Same rule as the alarm-ON sheet: without snapping the panel rests
            // at whatever fraction the finger left it at, so a lazy flick parks
            // the guide at a height that was never budgeted against the map.
            snap: true,
            snapSizes: f.snapSizes,
            builder: (context, controller) => Container(
              decoration: const BoxDecoration(
                color: NavAlertColors.surface,
                // Rounded at the TOP only. This is the top of the sheet+footer
                // unit; its bottom edge is flush against the footer, so a
                // rounded bottom would cut two notches of map into the seam.
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                // Offset upward, not centred. An un-offset shadow bleeds DOWN
                // across the joint with the footer and draws a dark line
                // between two plates that are supposed to read as one panel.
                // Lifting it only against the map is the whole job here.
                boxShadow: [
                  BoxShadow(
                      color: Colors.black45,
                      blurRadius: 12,
                      offset: Offset(0, -4)),
                ],
              ),
              // The SAME leg cards the planning guide and the alarm-ON sheet
              // draw — one component, three surfaces.
              child: CommuteGuideSheet(inline: true, controller: controller),
            ),
          ),
        );
      });

  // ── Header plate ───────────────────────────────────────────────────────
  // Back · destination · alarm toggle, then the step counter. Unchanged from
  // the column layout except for the plate behind it.
  Widget _header(BuildContext context, TripViewModel vm) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: NavAlertColors.background.withValues(alpha: 0.92),
          borderRadius:
              const BorderRadius.vertical(bottom: Radius.circular(20)),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
              child: Row(children: [
                const _BackToShellButton(),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('En Route',
                          style: TextStyle(
                              fontSize: 11,
                              color: NavAlertColors.textSecondary)),
                      Text(vm.trip!.destinationLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _AlarmToggleChip(vm: vm, compact: true),
              ]),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(children: [
                const Icon(Icons.route, size: 15, color: NavAlertColors.accent),
                const SizedBox(width: 6),
                Text(CommuteGuideSheet.stepLabel(vm.guide),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
        ),
      );

  // ── Footer plate — the safety controls ─────────────────────────────────
  // Everything that sat below the guide before, in the same order, with the
  // same styling. It is measured (see _footerKey) rather than assumed, so the
  // sheet's budget always reflects the footer actually on screen.
  Widget _footer(BuildContext context, TripViewModel vm) => Container(
        width: double.infinity,
        // SQUARE top, and the same surface as the sheet above it. The footer is
        // permanently flush beneath the sheet — they are adjacent siblings, at
        // every drag height — so rounding this edge cut two notches of map into
        // the seam and the different fill drew a hard line across it. Together
        // those made one panel look like two floating on top of each other.
        // Matching the sheet turns the pair into a single plate whose lower
        // section happens to hold the safety controls.
        decoration: const BoxDecoration(color: NavAlertColors.surface),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 8),
            // UC-1 Exception 2 — "Signal Lost" keeps its full card here too:
            // with the alarm off the rider is navigating by these steps, and
            // stale GPS is exactly what makes the step they are on wrong.
            if (vm.signalLostAlarm)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Card(
                  color: const Color(0xFF4A2A00),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.gps_off,
                        color: NavAlertColors.warning),
                    title: const Text('Signal Lost',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: const Text(
                        'GPS has been unavailable - stay alert for your stop.',
                        style: TextStyle(fontSize: 11)),
                    trailing: ElevatedButton(
                      onPressed: vm.dismissSignalLostAlarm,
                      child: const Text('Dismiss'),
                    ),
                  ),
                ),
              )
            else if (vm.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(vm.error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: NavAlertColors.warning, fontSize: 12)),
              ),
            // Monitoring demoted to one strip: still honest about distance and
            // ETA, no longer the subject of the screen.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child:
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(_MonitoringText.distance(vm),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
                const Text('  ·  ',
                    style: TextStyle(color: NavAlertColors.textSecondary)),
                Flexible(
                  child: Text(_MonitoringText.speedAndEta(vm),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: NavAlertColors.textSecondary)),
                ),
              ]),
            ),
            _EmergencyActionsRow(vm: vm),
            const SizedBox(height: 12),
            // DO NOT MODIFY LOGIC: the anti-oversleep gesture — the only way to
            // end monitoring. Keep onCompleted → stopTrip() + pop(). You may
            // restyle the slider (see _SlideToStop below); do not lower its
            // completion threshold (it guards against a stray-thumb dismiss).
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: _SlideToStop(onCompleted: () async {
                await vm.stopTrip();
                if (context.mounted) Navigator.of(context).pop();
              }),
            ),
          ]),
        ),
      );
}

/// The distance / speed / ETA strings, in one place.
///
/// _Monitoring built these as instance getters, which the guide-first layout
/// can no longer reach now that it is its own widget. Lifting them out keeps
/// ONE copy of the formatting rather than letting the alarm-ON screen and the
/// guide footer round the same numbers differently.
class _MonitoringText {
  const _MonitoringText._();

  static String distance(TripViewModel vm) {
    final km = vm.distanceM / 1000;
    return km >= 1
        ? '${km.toStringAsFixed(1)} km away'
        : '${vm.distanceM.toStringAsFixed(0)} m away';
  }

  static String speedAndEta(TripViewModel vm) =>
      'speed ${vm.speedKmh.toStringAsFixed(0)} km/h'
      '${vm.etaMinutes == null ? '' : '  ·  ETA ${vm.etaMinutes!.round()} min'}';
}

/// ╔════════════════════════════════════════════════════════════╗
/// ║ DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:           ║
/// ║ MID-TRIP ALARM ARM/DISARM. The alarm is opt-in per trip, so ║
/// ║ this is the ONLY way to arm it once a trip has started.     ║
/// ║                                                            ║
/// ║ UI TEAM: restyle the chip freely — colours, icon, shape,    ║
/// ║ copy. Keep it bound to vm.trip!.alarmEnabled and keep the   ║
/// ║ onPressed wired to vm.setAlarmEnabled. Removing it strands  ║
/// ║ a rider who started without the alarm and then wants it.    ║
/// ╚════════════════════════════════════════════════════════════╝
///
/// Lifted out of _Monitoring unchanged so BOTH monitoring layouts (Figure 24
/// when the alarm is on, guide-first when it is off) drive the one control.
/// Duplicating it would be the surest way to let one copy lose its wiring —
/// and in the guide-first layout this chip matters most, because it is the
/// only route from "just following the steps" to an armed alarm.
class _AlarmToggleChip extends StatelessWidget {
  const _AlarmToggleChip({required this.vm, this.compact = false});
  final TripViewModel vm;

  /// Guide-first header form: icon + short label, no full sentence.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final on = vm.trip!.alarmEnabled;
    return ActionChip(
      avatar: Icon(on ? Icons.alarm_on : Icons.alarm_off,
          size: 18,
          color: on ? NavAlertColors.success : NavAlertColors.textSecondary),
      label: Text(
          compact
              ? (on ? 'Alarm on' : 'Alarm off')
              : (on
                  ? 'Alarm on - tap to turn off'
                  : 'Alarm off - tap to turn on'),
          style: compact ? const TextStyle(fontSize: 12) : null),
      backgroundColor: NavAlertColors.surface,
      onPressed: () => vm.setAlarmEnabled(!vm.trip!.alarmEnabled),
    );
  }
}

/// ╔════════════════════════════════════════════════════════════╗
/// ║ DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:           ║
/// ║ SPAM-TAP DEBOUNCERS for the SOS and Fake Call buttons.     ║
/// ║                                                            ║
/// ║ UI TEAM: `em.sending` and `em.fakeCallActive` are the      ║
/// ║ in-flight (isProcessing) flags. Restyle these buttons all  ║
/// ║ you like — colours, icons, sizes, spacing, the label copy. ║
/// ║ Do NOT replace the `onPressed: <flag> ? null : ...`        ║
/// ║ pattern with a plain handler, and do NOT drop the Builder  ║
/// ║ or its context.watch — that is what re-enables the button  ║
/// ║ when the action finishes. Hard-wiring onPressed lets a     ║
/// ║ panic-tapping rider fire duplicate SOS texts (real cost:   ║
/// ║ their prepaid load) and stack fake-call screens.           ║
/// ╚════════════════════════════════════════════════════════════╝
///
/// The ViewModel guards (fireSos's `sending` flag, startFakeCall's
/// `fakeCallActive` gate) already stop the work running twice, but an
/// enabled-looking button that silently eats taps reads as "the app is broken"
/// at the exact moment the rider needs it — so the state is visible, not just
/// enforced.
///
/// Lifted out of _Monitoring VERBATIM — same Builder, same context.watch, same
/// `onPressed: <flag> ? null : ...` pattern, same 40 px separation — so both
/// monitoring layouts share one copy of the wiring instead of two that can
/// drift apart.
class _EmergencyActionsRow extends StatelessWidget {
  const _EmergencyActionsRow({required this.vm});
  final TripViewModel vm;

  @override
  Widget build(BuildContext context) {
    return Builder(builder: (context) {
      final em = context.watch<EmergencyViewModel>();
      return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
              backgroundColor: NavAlertColors.danger,
              minimumSize: const Size(140, 48),
              alignment: Alignment.center),
          onPressed: em.sending
              ? null
              : () => context
                  .read<EmergencyViewModel>()
                  .fireSos(tripId: vm.trip!.tripId),
          icon: const Icon(Icons.warning_amber, size: 18),
          label: Text(em.sending ? 'Sending…' : 'SOS'),
        ),
        // DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:
        // SOS and Fake Call are DIFFERENT emergency actions and must stay
        // physically separated. They were 14 px apart, which on a moving
        // jeepney is close enough for one thumb to catch both — the likeliest
        // cause of "SOS and the recording trigger at the same time". Narrowed
        // from 40px to 24px on request, still well clear of the 14px that
        // caused the original mis-tap — do not go below this.
        const SizedBox(width: 24),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
              minimumSize: const Size(140, 48), alignment: Alignment.center),
          onPressed: em.fakeCallActive
              ? null
              : () async {
                  final em = context.read<EmergencyViewModel>();
                  // Push only if this tap started the call — see the panic-tap
                  // guard in startFakeCall.
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
    });
  }
}

/// The back arrow the directive asks for, and the reason it is safe.
///
/// This is a PROGRAMMATIC Navigator.pop(), which is exactly what the PopScope
/// guard above already exempts: that guard blocks the SYSTEM back gesture and
/// the edge swipe, and its own comment records that it "does not affect
/// programmatic Navigator.pop(), so Slide-to-Stop and the summary's Done/Close
/// buttons still close this screen exactly as before". This button is one more
/// of those deliberate exits, so the guard is untouched.
///
/// Leaving is NOT ending the trip. Monitoring lives in TripViewModel, not in
/// this route: the GPS stream, the escalation timers and the alarm keep running
/// — _fireStage plays the alarm from the ViewModel, so it sounds whether or not
/// this screen is mounted — and the shell floats a "View Active Trip" pill to
/// come straight back. Every Active Trip mockup draws the bottom navigation
/// bar, so a rider who can reach their other tabs mid-trip is the designed
/// behaviour, not a hole in it.
///
/// Deliberately only rendered on the MONITORING screen. An alarm stage or the
/// overshoot prompt must stay a hard-to-leave alert (R1), and those phases
/// never build this widget.
class _BackToShellButton extends StatelessWidget {
  const _BackToShellButton();

  @override
  Widget build(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        tooltip: 'Back - the trip keeps running',
        onPressed: () {
          final messenger = ScaffoldMessenger.of(context);
          Navigator.of(context).pop();
          messenger.showSnackBar(const SnackBar(
              content: Text('Trip still running - tap "View Active Trip" to '
                  'come back.')));
        },
      );
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
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/images/alarm/alarm_stage_3_bg.jpg'),
            fit: BoxFit.cover,
          ),
        ),
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
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage('assets/images/alarm/alarm_stage_1_2_bg.jpg'),
          fit: BoxFit.cover,
        ),
      ),
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
                    content: Text('Could not stop the trip - please try '
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
