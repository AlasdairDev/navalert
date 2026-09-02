import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// One map tile in the standard slippy-map scheme.
@immutable
class TileRef {
  const TileRef(this.z, this.x, this.y);
  final int z, x, y;

  @override
  bool operator ==(Object other) =>
      other is TileRef && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => '$z/$x/$y';
}

/// Warms the disk tile cache along a planned route, while the phone still has
/// the signal it was planned on.
///
/// The offline map was the point of [TileCacheStore], but it only ever held
/// tiles the commuter had already LOOKED at — so a route planned at home and
/// ridden through a dead zone opened on a blank grey page with a coloured line
/// floating on it. The geometry was right and the map underneath it was
/// missing, which reads as a broken app rather than as a missing network.
///
/// This closes that gap at the one moment it can be closed: the planning
/// screen, where the route is known and the connection still exists.
///
/// ## Deliberately small and slow
/// OSM's Tile Usage Policy prohibits bulk downloading, and it is a free service
/// run on donated hardware. This is therefore NOT an area downloader: it walks
/// the thin ribbon of tiles the drawn route actually passes through, at the two
/// zooms the trip map uses, capped at [maxTiles] and issued a few at a time.
/// For a typical Metro Manila commute that is well under a hundred requests —
/// fewer than idly panning around the same route by hand, which nobody
/// considers abuse. The cap is a hard stop, not a target.
///
/// Failures are silent and partial results are kept: a warmed cache is an
/// optimisation, and a commuter must never be blocked from starting a trip
/// because some tiles did not arrive.
class TilePrefetchService {
  TilePrefetchService._();
  static final TilePrefetchService instance = TilePrefetchService._();

  /// Zooms to warm.
  ///
  /// 16 is what the trip map follows at (`_followZoom` 16.5 resolves to native
  /// 16). 15 is included because it is one pinch out, costs a quarter as many
  /// tiles, and without it the first thing a commuter does when lost — zoom out
  /// — lands back on grey.
  static const List<int> zooms = [15, 16];

  /// How far either side of the route to warm, in tiles.
  ///
  /// 1 gives a three-tile-wide ribbon. Zero would cover only the tiles the line
  /// crosses, so the map would be blank as soon as the camera drifted a street
  /// off the route — which it does constantly, since it follows the rider.
  static const int ring = 1;

  /// Hard ceiling on one warm, across all zooms.
  static const int maxTiles = 320;

  /// Requests in flight at once. Low on purpose — see the policy note above.
  static const int concurrency = 4;

  bool _busy = false;

  /// The tile containing a coordinate, by the standard slippy-map projection.
  static TileRef tileFor(double lat, double lng, int z) {
    final n = 1 << z;
    final latRad = lat * math.pi / 180.0;
    var x = ((lng + 180.0) / 360.0 * n).floor();
    var y = ((1 -
                math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
            2 *
            n)
        .floor();
    // Clamped rather than wrapped: a coordinate outside the projection is a bad
    // fix, and warming a tile on the far side of the world helps nobody.
    x = x.clamp(0, n - 1);
    y = y.clamp(0, n - 1);
    return TileRef(z, x, y);
  }

  /// Every tile within [ring] of the route [path], at each of [zooms].
  ///
  /// Ordered from the START of the route outward, so that if the cap or the
  /// connection cuts the warm short, what got cached is the part of the journey
  /// the commuter reaches FIRST — the leg they are about to walk, not the one
  /// they will ride in forty minutes.
  static List<TileRef> corridor(
    List<List<double>> path, {
    List<int> zooms = TilePrefetchService.zooms,
    int ring = TilePrefetchService.ring,
    int cap = maxTiles,
  }) {
    final out = <TileRef>[];
    final seen = <TileRef>{};
    if (path.isEmpty) return out;
    for (final point in path) {
      if (point.length < 2) continue;
      for (final z in zooms) {
        final centre = tileFor(point[0], point[1], z);
        final n = 1 << z;
        for (var dx = -ring; dx <= ring; dx++) {
          for (var dy = -ring; dy <= ring; dy++) {
            final x = centre.x + dx, y = centre.y + dy;
            if (x < 0 || y < 0 || x >= n || y >= n) continue;
            final t = TileRef(z, x, y);
            if (seen.add(t)) {
              out.add(t);
              if (out.length >= cap) return out;
            }
          }
        }
      }
    }
    return out;
  }

  /// Fills a `{z}/{x}/{y}` template. `{r}` is the retina marker flutter_map
  /// substitutes; it must be resolved the same way here or the warmed URL will
  /// not be the one the map asks for.
  static String urlFor(String template, TileRef t, {required bool retina}) =>
      template
          .replaceAll('{z}', '${t.z}')
          .replaceAll('{x}', '${t.x}')
          .replaceAll('{y}', '${t.y}')
          .replaceAll('{r}', retina ? '@2x' : '');

  /// Warms the cache along [path]. Returns how many tiles were requested.
  ///
  /// Re-entrant calls are dropped rather than queued: a commuter flicking
  /// between the two suggested routes should not stack up warms.
  Future<int> warmRoute({
    required List<List<double>> path,
    required String template,
    required bool retina,
    required Dio dio,
    List<int>? zooms,
    Map<String, String> headers = const {},
  }) async {
    if (_busy || path.isEmpty) return 0;
    _busy = true;
    try {
      final tiles = corridor(path, zooms: zooms ?? TilePrefetchService.zooms);
      var done = 0;
      for (var i = 0; i < tiles.length; i += concurrency) {
        final batch = tiles.skip(i).take(concurrency).map((t) async {
          try {
            await dio.get<List<int>>(
              urlFor(template, t, retina: retina),
              options: Options(
                  responseType: ResponseType.bytes,
                  headers: headers.isEmpty ? null : headers),
            );
            done++;
          } catch (_) {
            // Expected in the ordinary case this exists for: the connection is
            // already going. Keep whatever did land.
          }
        });
        await Future.wait(batch);
      }
      debugPrint('NavAlert: warmed $done/${tiles.length} route tiles');
      return done;
    } finally {
      _busy = false;
    }
  }
}
