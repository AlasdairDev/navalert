import 'dart:math' as math;

/// Great-circle distance in metres.
double metersBetween(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLng = _rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

double _rad(double deg) => deg * math.pi / 180.0;

/// How close a search result must be to count as "the place you are standing
/// in" (Search, current-location matching).
///
/// 100 m is a compromise chosen deliberately. Smaller, and standing at the far
/// side of a campus like PUP stops counting as being there. Larger, and the
/// building next door gets flagged as your location, which is worse: it would
/// name a place the commuter is not at, the same fault the fallback-position
/// rule exists to prevent.
const double kAtLocationRadiusM = 100;

/// True when [lat]/[lng] is close enough to [fromLat]/[fromLng] to be treated
/// as the same place. False whenever either position is unknown — an unknown
/// position must never be reported as a match.
bool isAtLocation(
  double? fromLat,
  double? fromLng,
  double lat,
  double lng, {
  double radiusM = kAtLocationRadiusM,
}) {
  if (fromLat == null || fromLng == null) return false;
  return metersBetween(fromLat, fromLng, lat, lng) <= radiusM;
}
