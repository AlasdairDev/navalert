import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../services/guide_progress.dart';
import '../viewmodels/trip_viewmodel.dart';

/// Live commute guide shown during an active trip (Requirement R6).
///
/// Renders in one of two modes, from the SAME leg cards and the same
/// markGuideLegDone wiring, so the two surfaces can never drift apart:
///
///  * default — a collapsed draggable sheet. With the destination alarm ON the
///    monitoring screen still matches Figure 24 and keeps its "Get some rest.
///    We got you." premise: the guide is there when the rider wants it,
///    invisible when they do not.
///  * [inline] — a plain expanded list with no sheet chrome, for the
///    guide-first monitoring layout. With the alarm OFF the rider is using
///    NavAlert as a navigation guide, not an alarm clock, so the steps ARE the
///    screen and a collapsed drag handle would bury the only thing they came
///    for. Meant to be dropped into an Expanded.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] the leg list in order, the current-leg highlight, and the "Done"
///         button (the only way to advance a synthetic leg). Renders nothing
///         when the guide is empty.
///  [EDIT] sheet height, handle, card colours, icons, typography, the
///         completed-leg styling.
///  [WANT] per-leg ETA countdown, a map preview per leg, haptic tick when a
///         leg auto-advances.
class CommuteGuideSheet extends StatelessWidget {
  const CommuteGuideSheet({super.key, this.inline = false});

  /// Render as an expanded inline list rather than a draggable bottom sheet.
  final bool inline;

  /// Fraction of screen height the sheet occupies when collapsed — just the
  /// drag handle and the step counter.
  static const double collapsedFraction = 0.062;

  /// DO NOT MODIFY LOGIC: the collapsed size must include the bottom system
  /// inset. The sheet is measured from the very bottom of the Scaffold body,
  /// which extends BEHIND the gesture-navigation bar — and 0.062 of the screen
  /// is only about 57 logical pixels, roughly the height of that bar. The
  /// collapsed sheet was therefore drawn almost entirely underneath it, leaving
  /// the step counter jammed into the navigation pill. Growing by the inset
  /// lifts the handle and counter clear of it.
  static double _collapsedFractionFor(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    if (height <= 0) return collapsedFraction;
    final inset = MediaQuery.paddingOf(context).bottom;
    return (collapsedFraction + inset / height).clamp(collapsedFraction, 0.5);
  }

  /// Logical pixels the monitoring screen must reserve at its bottom so the
  /// collapsed sheet never overlaps the SOS / Fake Call controls.
  static double collapsedHeight(BuildContext context) =>
      MediaQuery.sizeOf(context).height * _collapsedFractionFor(context);

  /// "Step 2 of 4" — shared by the sheet's own header and by the guide-first
  /// layout's header, so the two surfaces can never disagree about which step
  /// is live.
  static String stepLabel(GuideProgress guide) => guide.isComplete
      ? 'All steps done'
      : 'Step ${guide.currentIndex + 1} of ${guide.legs.length}';

  @override
  Widget build(BuildContext context) {
    // DO NOT MODIFY LOGIC: `guide` (GuideProgress) tracks which leg the rider
    // is on. GTFS legs auto-advance from GPS; synthetic legs advance on the
    // "Done" tap → vm.markGuideLegDone. Restyle the sheet/cards, but keep the
    // reads of guide.legs / guide.currentIndex and the markGuideLegDone call.
    final vm = context.watch<TripViewModel>();
    final guide = vm.guide;
    // No guide for this trip (e.g. started from Favorites) — show nothing at
    // all rather than an empty panel the rider has to dismiss.
    if (guide.isEmpty) return const SizedBox.shrink();

    // Guide-first layout: no handle, no rounded sheet plate, no snap sizes —
    // the caller has already given this the body of the screen. The step
    // counter moves into the caller's header, so it is not repeated here.
    if (inline) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        children: [
          for (var i = 0; i < guide.legs.length; i++)
            _legCard(vm, i, i == guide.currentIndex, i < guide.currentIndex),
        ],
      );
    }

    final collapsed = _collapsedFractionFor(context);
    return DraggableScrollableSheet(
      // Collapsed height must stay small enough that the SOS and Fake Call
      // buttons underneath remain fully tappable — they are safety controls
      // and must never be covered by a convenience panel. ActiveTripView pads
      // the monitoring body by [collapsedHeight] to match.
      initialChildSize: collapsed,
      minChildSize: collapsed,
      maxChildSize: 0.62,
      // DO NOT MODIFY LOGIC: without snapping, DraggableScrollableSheet rests
      // at WHATEVER fraction the finger was released at. A quick flick down left
      // the guide parked half-open over the monitoring screen — covering the SOS
      // and Fake Call buttons that ActiveTripView only reserves [collapsedHeight]
      // for. A convenience panel must never be able to sit on the safety
      // controls, so the sheet is now always either fully collapsed or fully
      // open, and never in between.
      snap: true,
      snapSizes: [collapsed, 0.62],
      builder: (context, controller) => Container(
        decoration: const BoxDecoration(
          color: NavAlertColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: ListView(
          controller: controller,
          // Bottom inset keeps the last card clear of the navigation bar too.
          padding: EdgeInsets.fromLTRB(
              16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: NavAlertColors.textSecondary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Center(
              child: Text(
                'Commute guide · ${stepLabel(guide).toLowerCase()}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < guide.legs.length; i++)
              _legCard(vm, i, i == guide.currentIndex, i < guide.currentIndex),
          ],
        ),
      ),
    );
  }

  Widget _legCard(TripViewModel vm, int i, bool isCurrent, bool isDone) {
    final leg = vm.guide.legs[i];
    final step = leg.step;
    return Opacity(
      opacity: isDone ? 0.45 : 1,
      child: Card(
        color: isCurrent ? NavAlertColors.primary.withValues(alpha: 0.22) : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Same round mode badge the planning guide on RouteView uses, so
            // the live sheet and the sheet the rider chose the route on read
            // as one component rather than two different lists.
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: NavAlertColors.surface,
              ),
              child: Icon(_iconFor(step.transportMode),
                  size: 17,
                  color: isDone
                      ? NavAlertColors.textSecondary
                      : NavAlertColors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Ride leg: surface the boarding terminal prominently so the
                  // rider knows exactly where to get on.
                  if (step.transportMode != 'walk' &&
                      (step.fromStop?.isNotEmpty ?? false))
                    Text('Board at ${step.fromStop}',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            decoration:
                                isDone ? TextDecoration.lineThrough : null)),
                  Text(step.instruction,
                      style: TextStyle(
                          fontSize: 13,
                          color: (step.transportMode != 'walk' &&
                                  (step.fromStop?.isNotEmpty ?? false))
                              ? NavAlertColors.textSecondary
                              : null,
                          decoration:
                              isDone ? TextDecoration.lineThrough : null)),
                  // Clock glyph + fare pill, matching the planning guide on
                  // RouteView. The pill sits on the `background` token rather
                  // than the lighter tint used there, because the CURRENT leg's
                  // card is itself tinted with primary — a pill of that same
                  // colour would vanish on exactly the one row that matters.
                  if (step.farePhp > 0 || step.durationMinutes > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Row(children: [
                        if (step.durationMinutes > 0) ...[
                          const Icon(Icons.schedule,
                              size: 11, color: NavAlertColors.textSecondary),
                          const SizedBox(width: 3),
                          Text('${step.durationMinutes.round()} min',
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: NavAlertColors.textSecondary)),
                        ],
                        if (step.farePhp > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: NavAlertColors.background,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                                '₱${step.farePhp.toStringAsFixed(2)}',
                                style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ]),
                    ),
                  if (isCurrent)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: vm.markGuideLegDone,
                        child: const Text('Done'),
                      ),
                    ),
                ],
              ),
            ),
            if (isDone)
              const Icon(Icons.check_circle,
                  size: 18, color: NavAlertColors.success),
          ]),
        ),
      ),
    );
  }

  IconData _iconFor(String mode) => switch (mode) {
        'walk' => Icons.directions_walk,
        'bus' => Icons.directions_bus,
        'uv_express' => Icons.airport_shuttle,
        _ => Icons.directions_transit,
      };
}
