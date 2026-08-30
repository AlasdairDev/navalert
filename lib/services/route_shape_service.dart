import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../core/geo.dart';

/// The route name a commute-guide step tells the commuter to ride, or null
/// for a walking step.
///
/// RouteEngine writes the name in quotes — `Ride jeepney "BACLARAN - DAPITAN
/// via TAFT" and alight at ...` — so the quoted span is the route as the
/// bundled feed names it, which is exactly the key the shapes table uses.
///
/// Reading the name matters because matching a shape by PROXIMITY alone draws
/// whichever route happens to run near both ends of the trip, not the one the
/// commuter was told to board. On a walking suggestion it drew a jeepney route
/// nobody was riding.
String? routeNameFromInstruction(String instruction) {
  final m = RegExp(r'"([^"]+)"').firstMatch(instruction);
  final name = m?.group(1)?.trim();
  return (name == null || name.isEmpty) ? null : name;
}

/// One PUV route whose road path passes near a point.
class NearbyRoute {
  final int id;
  final String name;
  final String mode;

  /// Metres from the query point to the nearest point on this route's path.
  final double distanceM;

  /// Decoded road geometry, [lat, lng] pairs.
  final List<List<double>> path;

  const NearbyRoute({
    required this.id,
    required this.name,
    required this.mode,
    required this.distanceM,
    required this.path,
  });
}

/// Phase 2 — answers "which jeepney routes run near me" from the bundled
/// database, with no network at all.
///
/// The shapes are generated at build time by `tool/gen_shapes.py` (Phase 1),
/// which routes through every stop of every route and stores the simplified
/// geometry as an encoded polyline. At runtime this only reads.
///
/// WHY AN R-TREE PRE-FILTER
/// Answering this by brute force means a point-to-polyline test against all
/// 1,711 shapes — on the order of a million distance calculations per GPS fix,
/// which a phone cannot do at 1 Hz. The R-tree narrows it by bounding box
/// first, so the exact test runs on the handful that could possibly match.
class RouteShapeService {
  RouteShapeService._();
  static final RouteShapeService instance = RouteShapeService._();

  static const _asset = 'assets/gtfs/shapes.db';
  static const _fileName = 'shapes.db';

  Database? _db;
  Future<Database?>? _opening;

  /// Copies the read-only asset out on first use — sqlite cannot open a file
  /// inside the APK. Returns null if the asset is absent, so a build without
  /// generated shapes degrades instead of crashing.
  Future<Database?> _open() => _opening ??= () async {
        try {
          final dir = await getApplicationSupportDirectory();
          final path = p.join(dir.path, _fileName);
          final file = File(path);
          final bytes = await rootBundle.load(_asset);
          // Re-copy when the bundled asset changes size (a new build).
          if (!await file.exists() ||
              await file.length() != bytes.lengthInBytes) {
            await file.writeAsBytes(
                bytes.buffer.asUint8List(
                    bytes.offsetInBytes, bytes.lengthInBytes),
                flush: true);
          }
          _db = await openDatabase(path, readOnly: true);
          return _db;
        } catch (e) {
          debugPrint('NavAlert: route shapes unavailable — $e');
          return null;
        }
      }();

  /// Routes whose road path passes within [radiusM] of the point, nearest
  /// first. Empty when the database is missing or nothing is in range.
  Future<List<NearbyRoute>> near(
    double lat,
    double lng, {
    double radiusM = 500,
    int limit = 10,
  }) async {
    final db = await _open();
    if (db == null) return const [];

    // Degrees of slack for the bbox query. Latitude is ~111.32 km/deg
    // everywhere; longitude shrinks with latitude, so it is computed here
    // rather than assumed — at 14.6 N a degree of longitude is ~10% shorter.
    final dLat = radiusM / 111320.0;
    final cos = _cosLat(lat);
    final dLng = radiusM / (111320.0 * (cos.abs() < 1e-6 ? 1e-6 : cos));

    try {
      final rows = await db.rawQuery(
        'SELECT s.id, s.name, s.mode, s.polyline FROM shape_bbox b '
        'JOIN shapes s ON s.id = b.id '
        'WHERE b.max_lat >= ? AND b.min_lat <= ? '
        '  AND b.max_lng >= ? AND b.min_lng <= ?',
        [lat - dLat, lat + dLat, lng - dLng, lng + dLng],
      );

      final out = <NearbyRoute>[];
      for (final r in rows) {
        final path = decodePolyline(r['polyline'] as String);
        final d = distanceToPolylineM(lat, lng, path);
        if (d <= radiusM) {
          out.add(NearbyRoute(
            id: r['id'] as int,
            name: r['name'] as String,
            mode: r['mode'] as String,
            distanceM: d,
            path: path,
          ));
        }
      }
      out.sort((a, b) => a.distanceM.compareTo(b.distanceM));
      return out.length > limit ? out.sublist(0, limit) : out;
    } catch (e) {
      debugPrint('NavAlert: route shape query failed — $e');
      return const [];
    }
  }

  /// The stored road geometry for the named route that actually serves this
  /// trip, or null.
  ///
  /// A NAME IS NOT UNIQUE. The bundled feed files most corridors more than
  /// once: 798 names carry several shapes, covering 1,622 of the 1,711 routes,
  /// and those shapes genuinely differ — one name was measured with variants of
  /// 342, 287, 13 and 9 points. Taking the first match would sometimes draw a
  /// nine-point stub in place of the real route.
  ///
  /// So the variants are ranked by how well each serves THIS trip: the one
  /// whose road passes closest to the origin and the destination wins, scored
  /// on the worse of the two ends so a shape cannot qualify on one end alone.
  /// Ties break toward the more detailed shape.
  Future<List<List<double>>?> pathForName(
    String name, {
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
    double maxEndDistanceM = 500,
  }) async {
    final db = await _open();
    if (db == null) return null;
    try {
      final rows = await db
          .rawQuery('SELECT polyline FROM shapes WHERE name = ?', [name]);
      if (rows.isEmpty) return null;

      List<List<double>>? best;
      var bestScore = double.infinity;
      for (final r in rows) {
        final path = decodePolyline(r['polyline'] as String);
        if (path.length < 2) continue;
        final score = variantScoreM(path, fromLat, fromLng, toLat, toLng);
        if (score < bestScore ||
            (score == bestScore && best != null && path.length > best.length)) {
          bestScore = score;
          best = path;
        }
      }
      // A shape that comes nowhere near the trip is the wrong variant, and
      // drawing it would put the commuter on a road they are not travelling.
      if (best == null || bestScore > maxEndDistanceM) return null;
      return best;
    } catch (e) {
      debugPrint('NavAlert: route shape lookup by name failed — $e');
      return null;
    }
  }

  /// The stored road geometry for one route, or null if absent.
  Future<List<List<double>>?> pathFor(int id) async {
    final db = await _open();
    if (db == null) return null;
    try {
      final rows = await db.rawQuery(
          'SELECT polyline FROM shapes WHERE id = ? LIMIT 1', [id]);
      if (rows.isEmpty) return null;
      return decodePolyline(rows.first['polyline'] as String);
    } catch (e) {
      debugPrint('NavAlert: route shape lookup failed — $e');
      return null;
    }
  }

  static double _cosLat(double lat) =>
      metersBetween(lat, 0, lat, 1) / metersBetween(0, 0, 0, 1);
}
