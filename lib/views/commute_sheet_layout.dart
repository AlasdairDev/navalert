import 'dart:math' as math;

// Geometry and camera state for the commute guide once it floats OVER the live
// trip map, rather than replacing it.
//
// Both classes here are deliberately plugin-free and Flutter-free so they can be
// unit-tested headlessly — the same reason HomeFabLayout was lifted out of
// HomeView. On a device these rules are only observable by watching a moving map
// on a moving jeepney; as arithmetic they are provable.
//
// UI/UX MAP (see legend in core/theme.dart):
//  [NEED] the fraction ORDERING (min <= initial <= max) and the strictly
//         ascending snap sizes — Flutter asserts both, and the assertion fires
//         on the one screen a rider cannot leave except by Slide-to-Stop.
//  [EDIT] the four tuning constants below: how tall the sheet rests, how much
//         map must stay visible, the collapsed peek height.

/// The three fractions a `DraggableScrollableSheet` needs, already validated.
///
/// Always satisfies `0 < min <= initial <= max <= 1`, whatever it was built
/// from — see [CommuteSheetLayout.resolve].
class CommuteSheetFractions {
  const CommuteSheetFractions({
    required this.min,
    required this.initial,
    required this.max,
  });

  /// Collapsed: the drag handle and step counter, and nothing else.
  final double min;

  /// Resting: the height the sheet opens at and returns to.
  final double initial;

  /// Fully dragged up — still short of the top, so map context survives.
  final double max;

  /// Snap points, strictly ascending and inside `[min, max]`.
  ///
  /// Flutter asserts BOTH of those (`_impliedSnapSizes`), so duplicates are
  /// dropped rather than passed through: on a degenerate layout the three
  /// fractions can legitimately collapse onto each other, and shipping
  /// `[0.4, 0.4]` would crash the trip screen instead of merely looking wrong.
  List<double> get snapSizes {
    final out = <double>[];
    for (final s in [min, initial, max]) {
      if (out.isEmpty || s > out.last) out.add(s);
    }
    return out;
  }
}

/// Resting/expanded geometry for the guide sheet floating over the map.
class CommuteSheetLayout {
  const CommuteSheetLayout._();

  /// [EDIT] How much of the SCREEN the resting sheet wants for itself. The
  /// directive asks for "30% to 40%"; this is the preference, and
  /// [maxObscuredScreenFraction] is the ceiling that actually binds.
  static const double restingSheetScreenFraction = 0.34;

  /// [NEED] The rule the overlay exists to satisfy: the sheet AND the safety
  /// footer beneath it together may never cover more than half the screen, so
  /// the top half of the map is always readable at a glance.
  static const double maxObscuredScreenFraction = 0.50;

  /// [NEED] Map that must survive even at full extension — dragging the sheet
  /// up to read later steps must never cost the rider all map context.
  static const double minMapVisibleFraction = 0.22;

  /// [EDIT] Collapsed peek: enough for the drag handle and the step counter.
  static const double minSheetHeight = 88;

  /// One logical pixel of slack, so floating-point rounding in the
  /// pixels → fraction → pixels round trip can never tip the sheet over a
  /// budget it was computed to respect.
  static const double _slack = 1.0;

  /// Never emit a zero fraction: `DraggableScrollableSheet` accepts it, then
  /// renders a sheet with no drag target at all — the guide would be on screen
  /// but impossible to open.
  static const double _minFraction = 0.02;

  /// Resolves the sheet's fractions.
  ///
  /// [screenHeight] is the whole screen, which is what the visibility budgets
  /// are written against. [regionHeight] is the transparent band the sheet
  /// actually lives in (screen minus header minus footer) — Flutter measures
  /// `DraggableScrollableSheet` fractions against its PARENT, so the budgets
  /// have to be converted before they mean anything to it.
  ///
  /// DO NOT MODIFY LOGIC: every return path is clamped and re-ordered. Callers
  /// hand these straight to `DraggableScrollableSheet`, which asserts
  /// `min <= initial <= max`; a NaN or an inverted pair throws on the active
  /// trip screen, where PopScope blocks Back and the only way out is the
  /// Slide-to-Stop control the crash would take with it.
  static CommuteSheetFractions resolve({
    required double screenHeight,
    required double regionHeight,
    required double footerHeight,
  }) {
    // Floors of 1, not guards that bail out: a zero or negative height is a
    // transient measurement (the first layout pass, a collapsed parent), and
    // dividing by it yields NaN/Infinity fractions that fail Flutter's asserts
    // in a way that is very hard to trace back to here.
    final screen = math.max(screenHeight, 1.0);
    final region = math.max(regionHeight, 1.0);
    final footer = math.max(footerHeight, 0.0);

    // What the half-screen rule leaves for the sheet once the safety footer has
    // taken its share. This is a CEILING, not a target.
    final restingBudget =
        math.max(maxObscuredScreenFraction * screen - footer - _slack, 0.0);
    // The preference yields to the budget: a tall footer (the Signal Lost card
    // adds ~90 px) shrinks the guide rather than eating into the map half.
    var restingPx = math.min(restingSheetScreenFraction * screen, restingBudget);
    // ...and the collapsed peek yields to it too. When the footer is so tall
    // that even the peek would breach the budget, the budget still wins — the
    // map is the thing the rider is navigating by.
    restingPx = math.max(restingPx, math.min(minSheetHeight, restingBudget));

    final maxPx = math.min(
      math.max((1 - minMapVisibleFraction) * screen - footer - _slack, 0.0),
      region,
    );
    final minPx = math.min(minSheetHeight, restingPx);

    double frac(double px) => (px / region).clamp(_minFraction, 1.0);

    // Clamped in cascade so the ordering holds by construction rather than by
    // luck: each bound is floored at the one before it.
    final minF = frac(minPx);
    final initialF = frac(restingPx).clamp(minF, 1.0);
    final maxF = frac(maxPx).clamp(initialF, 1.0);

    return CommuteSheetFractions(min: minF, initial: initialF, max: maxF);
  }
}

/// Follow-the-rider camera state for the live trip map.
///
/// Two rules pull against each other:
///
///  * the camera must track the blue dot, or the map is decoration; and
///  * the rider must be able to look ahead down the route, or the map is
///    unusable — a fix lands every 1–2 s, so an unconditional follow drags the
///    camera back before they can read anything.
///
/// So follow is ON by default and released by a MANUAL pan only. That
/// distinction is load-bearing: the follow ITSELF moves the camera, and if a
/// programmatic move counted as a gesture, tracking would switch itself off on
/// the very first fix it handled and the feature would silently do nothing.
/// flutter_map reports `hasGesture == false` for `MapController.move`, which is
/// what [AnimatedMapMover] drives, so the two are distinguishable.
class TripCameraTracker {
  bool _following = true;

  /// True while the camera is tracking the rider.
  bool get following => _following;

  /// Fed from `MapOptions.onPositionChanged`. Only a real finger releases the
  /// camera; a programmatic move must leave tracking exactly as it found it,
  /// in EITHER direction — silently re-arming follow behind a rider who
  /// deliberately panned away is the same bug seen from the other side.
  void onPositionChanged({required bool hasGesture}) {
    if (hasGesture) _following = false;
  }

  /// The recenter control — the only way back to tracking.
  void recenter() => _following = true;

  /// Vertical camera offset that centres the rider in the band of map left
  /// VISIBLE above the sheet, instead of in the middle of the widget where the
  /// sheet would be sitting on top of them.
  ///
  /// The visible band is `[0, H - obscured]`, so its centre sits `obscured / 2`
  /// above the widget centre. flutter_map documents `Offset(0, y)` as moving
  /// the intended centre DOWN by `y`, hence the negative sign.
  ///
  /// Floored at zero: a negative [obscuredHeight] (a footer measured mid-layout
  /// is briefly nonsense) would otherwise push the dot DOWN, behind the very
  /// sheet this exists to clear.
  static double cameraOffsetY(double obscuredHeight) =>
      -math.max(obscuredHeight, 0.0) / 2;
}
