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

/// Decodes a Google encoded polyline into [lat, lng] pairs.
///
/// Shapes ship encoded because it is ~6x smaller than JSON floats — the
/// difference between a ~6 MB asset and one far too large to bundle.
List<List<double>> decodePolyline(String encoded, {int precision = 5}) {
  final factor = math.pow(10, precision).toDouble();
  final out = <List<double>>[];
  var index = 0, lat = 0, lng = 0;
  while (index < encoded.length) {
    for (var i = 0; i < 2; i++) {
      var shift = 0, result = 0;
      int b;
      do {
        if (index >= encoded.length) return out; // truncated input
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);
      final d = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      if (i == 0) {
        lat += d;
      } else {
        lng += d;
      }
    }
    out.add([lat / factor, lng / factor]);
  }
  return out;
}

/// Shortest distance in metres from a point to a polyline.
///
/// "Is this route near me" is a point-to-POLYLINE question, not
/// point-to-point: a route passing 20 m away has no stop anywhere near, and
/// comparing against stops alone would miss it entirely.
///
/// Uses an equirectangular projection local to the query point. Over a city
/// the error is far below the radii this is used with, and it avoids a
/// haversine per segment — which matters when this runs per GPS fix.
double distanceToPolylineM(double lat, double lng, List<List<double>> path) {
  if (path.isEmpty) return double.infinity;
  const ky = 111320.0;
  final kx = ky * math.cos(lat * math.pi / 180.0);
  final px = lng * kx, py = lat * ky;
  if (path.length == 1) {
    return math.sqrt(math.pow(px - path[0][1] * kx, 2) +
        math.pow(py - path[0][0] * ky, 2));
  }
  var best = double.infinity;
  for (var i = 0; i < path.length - 1; i++) {
    final ax = path[i][1] * kx, ay = path[i][0] * ky;
    final bx = path[i + 1][1] * kx, by = path[i + 1][0] * ky;
    final dx = bx - ax, dy = by - ay;
    double d;
    if (dx == 0 && dy == 0) {
      d = math.sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
    } else {
      var t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
      t = t.clamp(0.0, 1.0);
      final qx = ax + t * dx, qy = ay + t * dy;
      d = math.sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy));
    }
    if (d < best) best = d;
  }
  return best;
}

/// Index of the vertex on [path] nearest to the point.
int nearestVertexIndex(double lat, double lng, List<List<double>> path) {
  var best = double.infinity, bestI = 0;
  const ky = 111320.0;
  final kx = ky * math.cos(lat * math.pi / 180.0);
  for (var i = 0; i < path.length; i++) {
    final dx = (path[i][1] - lng) * kx, dy = (path[i][0] - lat) * ky;
    final d = dx * dx + dy * dy;                 // squared: ordering only
    if (d < best) {
      best = d;
      bestI = i;
    }
  }
  return bestI;
}

/// The portion of [path] between the points nearest [fromLat]/[fromLng] and
/// [toLat]/[toLng], in travel order.
///
/// A stored shape is the WHOLE route, terminal to terminal. Drawing all of it
/// for a two-kilometre trip runs the line off both edges of the map and tells
/// the commuter nothing about their own journey — the map should show the ride
/// they are taking, not the route's entire length.
List<List<double>> trimPolyline(
  List<List<double>> path,
  double fromLat,
  double fromLng,
  double toLat,
  double toLng,
) {
  if (path.length < 2) return path;
  var a = nearestVertexIndex(fromLat, fromLng, path);
  var b = nearestVertexIndex(toLat, toLng, path);
  if (a == b) return path;
  // Routes are stored in travel order, but a commuter may ride either way.
  final reversed = a > b;
  if (reversed) {
    final t = a;
    a = b;
    b = t;
  }
  final seg = path.sublist(a, b + 1);
  return reversed ? seg.reversed.toList() : seg;
}

/// How well a candidate shape serves a trip: the distance from the WORSE of
/// its two ends to the road.
///
/// The worse end decides on purpose. A route name in the bundled feed is not
/// unique — most corridors are filed several times, and the variants genuinely
/// differ — so a variant must serve BOTH ends of the trip to be the right one.
/// Scoring on the better end alone would let a shape that merely brushes the
/// origin win over the route the commuter is actually riding.
double variantScoreM(
  List<List<double>> path,
  double fromLat,
  double fromLng,
  double toLat,
  double toLng,
) {
  final a = distanceToPolylineM(fromLat, fromLng, path);
  final b = distanceToPolylineM(toLat, toLng, path);
  return a > b ? a : b;
}
