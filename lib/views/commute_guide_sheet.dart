import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../viewmodels/trip_viewmodel.dart';

/// Live commute guide shown during an active trip (Requirement R6).
///
/// Collapsed to a drag handle by default so the monitoring screen still
/// matches Figure 24 and keeps its "Get some rest. We got you." premise —
/// the guide is there when the rider wants it, invisible when they do not.
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
  const CommuteGuideSheet({super.key});

  /// Fraction of screen height the sheet occupies when collapsed — just the
  /// drag handle and the step counter.
  static const double collapsedFraction = 0.062;

  /// Logical pixels the monitoring screen must reserve at its bottom so the
  /// collapsed sheet never overlaps the SOS / Fake Call controls.
  static double collapsedHeight(BuildContext context) =>
      MediaQuery.sizeOf(context).height * collapsedFraction;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TripViewModel>();
    final guide = vm.guide;
    // No guide for this trip (e.g. started from Favorites) — show nothing at
    // all rather than an empty panel the rider has to dismiss.
    if (guide.isEmpty) return const SizedBox.shrink();

    return DraggableScrollableSheet(
      // Collapsed height must stay small enough that the SOS and Fake Call
      // buttons underneath remain fully tappable — they are safety controls
      // and must never be covered by a convenience panel. ActiveTripView pads
      // the monitoring body by [collapsedHeight] to match.
      initialChildSize: collapsedFraction,
      minChildSize: collapsedFraction,
      maxChildSize: 0.62,
      builder: (context, controller) => Container(
        decoration: const BoxDecoration(
          color: NavAlertColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
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
                guide.isComplete
                    ? 'Commute guide · all steps done'
                    : 'Commute guide · step ${guide.currentIndex + 1} of '
                        '${guide.legs.length}',
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
            Icon(_iconFor(step.transportMode),
                size: 20,
                color: isDone
                    ? NavAlertColors.textSecondary
                    : NavAlertColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(step.instruction,
                      style: TextStyle(
                          fontSize: 13,
                          decoration:
                              isDone ? TextDecoration.lineThrough : null)),
                  if (step.farePhp > 0 || step.durationMinutes > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        [
                          if (step.durationMinutes > 0)
                            '${step.durationMinutes.round()} min',
                          if (step.farePhp > 0)
                            '₱${step.farePhp.toStringAsFixed(2)}',
                        ].join('  ·  '),
                        style: const TextStyle(
                            fontSize: 11,
                            color: NavAlertColors.textSecondary),
                      ),
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
