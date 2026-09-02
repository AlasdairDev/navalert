import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/services/tile_prefetch_service.dart';

/// Pre-caching map tiles along a planned route.
///
/// The offline map only ever held tiles the commuter had already LOOKED at, so
/// a route planned at home and ridden through a dead zone opened on blank grey
/// with a coloured line floating on it — the geometry right, the map missing.
///
/// The arithmetic is tested rather than the network: which tiles, in what
/// order, and how many. Those are the decisions that make this a warm-up rather
/// than a bulk download, and OSM's usage policy draws a hard line between the
/// two.
void main() {
  // Along the Cubao → Sta. Mesa jeepney corridor.
  const cubaoLat = 14.6214, cubaoLng = 121.0500;

  group('tile projection', () {
    test('agrees with the standard slippy-map scheme', () {
      // Verified against the published formula for zoom 14 at this coordinate.
      final t = TilePrefetchService.tileFor(14.6, 121.0, 14);
      expect(t.z, 14);
      expect(t.x, 13698);
      expect(t.y, 7520);
    });

    test('a deeper zoom quarters the tile', () {
      final a = TilePrefetchService.tileFor(cubaoLat, cubaoLng, 15);
      final b = TilePrefetchService.tileFor(cubaoLat, cubaoLng, 16);
      expect(b.x ~/ 2, a.x);
      expect(b.y ~/ 2, a.y);
    });

    test('a nonsense coordinate is clamped, not wrapped', () {
      // A bad GPS fix must not send a request for a tile on the far side of
      // the world.
      final t = TilePrefetchService.tileFor(0, 1000, 10);
      expect(t.x, lessThan(1 << 10));
      expect(t.x, greaterThanOrEqualTo(0));
    });
  });

  group('the corridor', () {
    List<List<double>> route(int points) => [
          for (var i = 0; i < points; i++)
            [cubaoLat - i * 0.002, cubaoLng - i * 0.002],
        ];

    test('covers both zooms the trip map uses', () {
      final tiles = TilePrefetchService.corridor(route(10));
      expect(tiles.map((t) => t.z).toSet(), {15, 16});
    });

    test('is a ribbon, not an area', () {
      // Three tiles wide at each zoom. A 20 km trip must not turn into a
      // regional download — OSM's policy prohibits bulk fetching, and this is
      // a free service on donated hardware.
      final tiles = TilePrefetchService.corridor(route(40));
      final z16 = tiles.where((t) => t.z == 16);
      final xs = z16.map((t) => t.x).toSet();
      // A diagonal route: the spread in x should track its length, not its
      // bounding box area.
      expect(z16.length, lessThan(xs.length * 12),
          reason: 'the tile set has thickened into an area');
    });

    test('never exceeds the cap, however long the route', () {
      final tiles = TilePrefetchService.corridor(route(4000));
      expect(tiles.length, lessThanOrEqualTo(TilePrefetchService.maxTiles));
    });

    test('starts at the beginning of the journey', () {
      // If the cap or the connection cuts the warm short, what got cached must
      // be the leg the commuter reaches FIRST, not the one they ride in forty
      // minutes.
      final tiles = TilePrefetchService.corridor(route(4000), cap: 12);
      final first = TilePrefetchService.tileFor(cubaoLat, cubaoLng, 15);
      expect(tiles.take(9).any((t) => t.z == 15 && t.x == first.x && t.y == first.y),
          isTrue);
    });

    test('emits no duplicates', () {
      final tiles = TilePrefetchService.corridor(route(30));
      expect(tiles.toSet().length, tiles.length);
    });

    test('a stationary route still warms the tiles around it', () {
      // Origin and destination in the same place: degenerate, but it must not
      // produce an empty set and leave the commuter with nothing.
      final tiles = TilePrefetchService.corridor([
        [cubaoLat, cubaoLng],
        [cubaoLat, cubaoLng],
      ]);
      expect(tiles, isNotEmpty);
      expect(tiles.toSet().length, tiles.length);
    });

    test('an empty route warms nothing', () {
      expect(TilePrefetchService.corridor(const []), isEmpty);
    });

    test('a malformed point is skipped rather than throwing', () {
      final tiles = TilePrefetchService.corridor([
        [cubaoLat],
        [cubaoLat, cubaoLng],
      ]);
      expect(tiles, isNotEmpty);
    });
  });

  group('url building', () {
    const osm = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    const maptiler =
        'https://api.maptiler.com/maps/basic-v2-dark/256/{z}/{x}/{y}{r}.png?key=K';

    test('fills the slippy placeholders', () {
      expect(
        TilePrefetchService.urlFor(osm, const TileRef(16, 1, 2), retina: false),
        'https://tile.openstreetmap.org/16/1/2.png',
      );
    });

    test('resolves the retina marker exactly as flutter_map does', () {
      // The disk cache is keyed on the url, so a warmed tile that differs by
      // one character is a tile the map will never find.
      expect(
        TilePrefetchService.urlFor(maptiler, const TileRef(16, 1, 2),
            retina: true),
        'https://api.maptiler.com/maps/basic-v2-dark/256/16/1/2@2x.png?key=K',
      );
      expect(
        TilePrefetchService.urlFor(maptiler, const TileRef(16, 1, 2),
            retina: false),
        'https://api.maptiler.com/maps/basic-v2-dark/256/16/1/2.png?key=K',
      );
    });

    test('a template with no retina marker is unaffected by the flag', () {
      expect(
        TilePrefetchService.urlFor(osm, const TileRef(16, 1, 2), retina: true),
        TilePrefetchService.urlFor(osm, const TileRef(16, 1, 2), retina: false),
      );
    });
  });
}
