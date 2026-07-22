import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// One stop on a GTFS route.
class GtfsStop {
  final String name;
  final double lat;
  final double lng;
  const GtfsStop(this.name, this.lat, this.lng);
}

/// A public-transport route (jeepney or bus) with its ordered stops,
/// loaded from the bundled DOTC/Sakay Metro Manila GTFS feed.
class GtfsRoute {
  final String name;
  final String mode; // 'jeepney' | 'bus'
  final List<GtfsStop> stops;
  const GtfsRoute(this.name, this.mode, this.stops);
}

/// A direct route serving both the origin and the destination: board at
/// [boardStop], ride the named [route] to [alightStop], with walk distances.
class GtfsRouteMatch {
  final GtfsRoute route;
  final GtfsStop boardStop;
  final GtfsStop alightStop;
  final double walkToBoardM;
  final double walkFromAlightM;
  final double rideKm;
  const GtfsRouteMatch({
    required this.route,
    required this.boardStop,
    required this.alightStop,
    required this.walkToBoardM,
    required this.walkFromAlightM,
    required this.rideKm,
  });
}

/// Loads real Metro Manila jeepney/bus routes from the bundled GTFS asset and
/// finds direct routes between two points, so the commute guide can name
/// actual routes and boarding/alighting stops instead of synthetic legs.
///
/// The 0.77 MB gzipped asset is decompressed and parsed once in a background
/// isolate on first use (never on app startup) and cached for the session.
class GtfsService {
  GtfsService._();
  static final GtfsService instance = GtfsService._();

  List<GtfsRoute>? _routes;
  Future<List<GtfsRoute>>? _loading;

  Future<List<GtfsRoute>> _load() async {
    if (_routes != null) return _routes!;
    return _loading ??= _doLoad();
  }

  Future<List<GtfsRoute>> _doLoad() async {
    final data = await rootBundle.load('assets/gtfs/routes.json.gz');
    final bytes = data.buffer.asUint8List();
    // Decompress + JSON-decode off the UI thread.
    final decoded = await compute(_decodeGtfs, bytes);
    final routes = <GtfsRoute>[];
    for (final r in decoded) {
      final m = r as Map<String, dynamic>;
      final stops = <GtfsStop>[];
      for (final s in (m['s'] as List)) {
        final t = s as List;
        stops.add(GtfsStop(t[0] as String, (t[1] as num).toDouble(),
            (t[2] as num).toDouble()));
      }
      routes.add(GtfsRoute(m['n'] as String, m['m'] as String, stops));
    }
    _routes = routes;
    _loading = null;
    return routes;
  }

  /// Name of the nearest known transit stop to a point, or null if none is
  /// within [maxM]. Fills `nearest_stop_name` on alarm_events (Table 25) and
  /// overshoot_events (Table 26) so a rider reading their history sees
  /// "Cubao" instead of raw coordinates.
  ///
  /// Deliberately reads only the **already-cached** feed and never triggers a
  /// load: this runs while an alarm is firing, and decompressing the asset on
  /// that path could delay the very alert meant to wake the rider. The commute
  /// guide warms the cache during route planning, so it is normally ready.
  String? nearestStopName(double lat, double lng, {double maxM = 1500}) {
    final routes = _routes;
    if (routes == null) return null;
    String? best;
    var bestM = maxM;
    for (final r in routes) {
      for (final s in r.stops) {
        final d = _haversineM(lat, lng, s.lat, s.lng);
        if (d < bestM) {
          bestM = d;
          best = s.name;
        }
      }
    }
    return best;
  }

  /// Direct routes (no transfer) serving both points, cheapest walk first.
  /// Returns [] if the asset can't load, so callers can fall back gracefully.
  Future<List<GtfsRouteMatch>> directRoutes({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
    bool busEnabled = true,
    bool jeepneyEnabled = true,
    bool uvEnabled = true,
    double maxWalkM = 800,
    int limit = 4,
  }) async {
    List<GtfsRoute> routes;
    try {
      routes = await _load();
    } catch (_) {
      return const [];
    }

    // Match the synthetic engine's rule: if no mode is selected at all, treat
    // every mode as enabled. (UV Express isn't in this feed, so selecting only
    // UV yields no GTFS routes and the caller falls back to the synthetic
    // engine, which serves the UV option.)
    final anyMode = busEnabled || jeepneyEnabled || uvEnabled;
    final useBus = busEnabled || !anyMode;
    final useJeep = jeepneyEnabled || !anyMode;

    final matches = <GtfsRouteMatch>[];
    for (final route in routes) {
      if (route.mode == 'bus' && !useBus) continue;
      if (route.mode == 'jeepney' && !useJeep) continue;

      // Nearest stop to origin and to destination.
      var boardIdx = -1, alightIdx = -1;
      var boardM = double.infinity, alightM = double.infinity;
      for (var i = 0; i < route.stops.length; i++) {
        final s = route.stops[i];
        final dO = _haversineM(originLat, originLng, s.lat, s.lng);
        if (dO < boardM) {
          boardM = dO;
          boardIdx = i;
        }
        final dD = _haversineM(destLat, destLng, s.lat, s.lng);
        if (dD < alightM) {
          alightM = dD;
          alightIdx = i;
        }
      }
      // Must be walkable at both ends and travel in the route's direction.
      if (boardM > maxWalkM || alightM > maxWalkM) continue;
      if (alightIdx <= boardIdx) continue;

      var rideM = 0.0;
      for (var i = boardIdx; i < alightIdx; i++) {
        final a = route.stops[i], b = route.stops[i + 1];
        rideM += _haversineM(a.lat, a.lng, b.lat, b.lng);
      }
      if (rideM < 300) continue; // ignore trivially short rides

      matches.add(GtfsRouteMatch(
        route: route,
        boardStop: route.stops[boardIdx],
        alightStop: route.stops[alightIdx],
        walkToBoardM: boardM,
        walkFromAlightM: alightM,
        rideKm: rideM / 1000,
      ));
    }

    matches.sort((a, b) => (a.walkToBoardM + a.walkFromAlightM)
        .compareTo(b.walkToBoardM + b.walkFromAlightM));
    return matches.take(limit).toList();
  }
}

/// Top-level so it can run in a compute isolate.
List<dynamic> _decodeGtfs(Uint8List gzBytes) {
  final jsonBytes = gzip.decode(gzBytes);
  return jsonDecode(utf8.decode(jsonBytes)) as List<dynamic>;
}

double _haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

double _rad(double deg) => deg * math.pi / 180.0;
