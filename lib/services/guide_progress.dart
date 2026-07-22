import 'dart:math' as math;

import '../models/guide_leg.dart';

/// Tracks which commute-guide leg the rider is on during an active trip.
///
/// Hybrid advancement:
///  * **GTFS-matched legs** carry real coordinates and complete themselves once
///    the rider comes within [arrivalRadiusM] of the alight stop.
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

  /// How close the rider must be to a GTFS leg's alight stop for it to count as
  /// completed. Metro Manila stops sit close together, so this may fire
  /// slightly early — acceptable, because the rider can always tap to correct
  /// and a guide step is a display hint, not the destination alarm.
  static const double arrivalRadiusM = 150;

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

  /// Feeds a GPS fix in. Returns true if this fix completed the current leg.
  ///
  /// Advancement is monotonic: it only ever moves forward, one leg per fix, and
  /// never past the end. A synthetic leg is never advanced here at any distance.
  bool update(double lat, double lng) {
    final leg = currentLeg;
    if (leg == null || !leg.canAutoAdvance) return false;
    final d = _distanceM(lat, lng, leg.endLat!, leg.endLng!);
    if (d > arrivalRadiusM) return false;
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
