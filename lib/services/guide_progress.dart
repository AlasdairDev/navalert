import 'dart:math' as math;

import '../core/geo.dart';
import '../models/guide_leg.dart';

/// Tracks which commute-guide leg the rider is on during an active trip.
///
/// Hybrid advancement:
///  * **Legs with real coordinates** complete themselves once the rider comes
///    within [radiusFor] the leg of where it ends — the alight stop on a ride,
///    the terminal or the door on a walk.
///  * **Synthetic legs** have no coordinates and only ever advance on an
///    explicit tap — auto-advancing one would invent a location the rider never
///    passes.
///
/// Deliberately free of plugins and of any database or Flutter dependency, so
/// it can be unit-tested directly. Distance is computed locally rather than via
/// Geolocator for the same reason.
class GuideProgress {
  GuideProgress(this.legs);

  final List<GuideLeg> legs;

  /// How close the rider must be to a RIDE leg's alight stop for it to count as
  /// completed. Metro Manila stops sit close together, so this may fire
  /// slightly early — acceptable, and on a ride it is actively useful: the step
  /// turning over as the vehicle nears the stop is the cue to stand up. The
  /// rider can always tap to correct, and a guide step is a display hint, not
  /// the destination alarm.
  static const double arrivalRadiusM = 150;

  /// The same, for a WALK leg — tighter, and deliberately the SAME number the
  /// rest of the app already means by "you are standing at this place"
  /// ([kAtLocationRadiusM]).
  ///
  /// A walk ends where the rider physically has to be: at the terminal they
  /// board from, or at the door. 150 m is a block and a half away, and ticking
  /// "Walk to Cubao Terminal" off from across an intersection tells them to
  /// board a vehicle they are not yet standing next to. A ride is the opposite
  /// case — turning the step over as the vehicle nears the stop is the cue to
  /// stand up — so the two cannot share one number.
  ///
  /// Not tightened further than this on purpose. Urban GPS routinely reports
  /// 30–50 m of error between buildings, and a radius the rider cannot reliably
  /// enter is worse than one that fires early: it strands the guide on a step
  /// they have finished and puts them back to tapping it themselves, which is
  /// the exact failure automatic advancement exists to remove.
  static const double walkArrivalRadiusM = kAtLocationRadiusM;

  /// The radius [leg] completes within.
  static double radiusFor(GuideLeg leg) =>
      leg.step.transportMode == 'walk' ? walkArrivalRadiusM : arrivalRadiusM;

  int _index = 0;

  int get currentIndex => _index;

  bool get isEmpty => legs.isEmpty;

  /// True once every leg has been completed.
  bool get isComplete => legs.isNotEmpty && _index >= legs.length;

  GuideLeg? get currentLeg =>
      (_index >= 0 && _index < legs.length) ? legs[_index] : null;

  /// Rider tapped "Done". Always available, on either kind of leg, and always
  /// wins over auto-advance so an early automatic step can be corrected.
  /// Returns true if the index moved.
  bool markDone() {
    if (isComplete || isEmpty) return false;
    _index++;
    return true;
  }

  /// Completes every remaining leg at once.
  ///
  /// Called when the trip's destination is actually reached. The final leg of a
  /// commute guide is almost always a SYNTHETIC walking step ("Walk towards PUP
  /// Sta. Mesa") which carries no coordinates, so [update] can never advance it
  /// — [canAutoAdvance] is false and there is no alight stop to measure against.
  /// That left the last step permanently unticked even though the commuter had
  /// plainly arrived, and the trip then ran on until the overshoot detector
  /// latched and announced a missed stop the commuter had not missed.
  ///
  /// Arriving at the destination IS the event that finishes that walk, so the
  /// destination check completes the remainder rather than the guide trying to
  /// infer an endpoint it was never given.
  void completeAll() => _index = legs.length;

  /// Feeds a GPS fix in. Returns true if this fix completed the current leg.
  ///
  /// Advancement is monotonic: it only ever moves forward, one leg per fix, and
  /// never past the end. A synthetic leg is never advanced here at any distance.
  bool update(double lat, double lng) {
    final leg = currentLeg;
    if (leg == null || !leg.canAutoAdvance) return false;
    final d = _distanceM(lat, lng, leg.endLat!, leg.endLng!);
    if (d > radiusFor(leg)) return false;
    _index++;
    return true;
  }
}

double _distanceM(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusM = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * earthRadiusM * math.asin(math.min(1, math.sqrt(a)));
}

double _rad(double deg) => deg * math.pi / 180.0;
