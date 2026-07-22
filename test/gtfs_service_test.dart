import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/services/gtfs_service.dart';

/// GTFS lookup contract.
///
/// nearestStopName() runs while an alarm is firing. It must answer from the
/// already-cached feed and never trigger a load, because decompressing the
/// 0.77 MB asset on that path would delay the very alert meant to wake the
/// rider. A cold cache therefore has to return null immediately rather than
/// block — that non-blocking guarantee is what these tests pin down.
void main() {
  group('nearestStopName — never blocks the alarm path', () {
    test('returns null instead of loading when the feed is not cached', () {
      expect(
        GtfsService.instance.nearestStopName(14.5979, 121.0108),
        isNull,
      );
    });

    test('answers synchronously — the call cannot await a decompression', () {
      final watch = Stopwatch()..start();
      GtfsService.instance.nearestStopName(14.5979, 121.0108);
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(50),
          reason: 'a slow lookup here would delay the wake-up alarm');
    });

    test('is safe to call repeatedly, as every alarm stage does', () {
      for (var i = 0; i < 5; i++) {
        expect(GtfsService.instance.nearestStopName(14.6, 121.0), isNull);
      }
    });
  });

  group('GTFS value types', () {
    test('a stop carries its name and coordinates', () {
      const stop = GtfsStop('Cubao', 14.6200, 121.0530);
      expect(stop.name, 'Cubao');
      expect(stop.lat, 14.6200);
      expect(stop.lng, 121.0530);
    });

    test('a route keeps its mode and ordered stops', () {
      const route = GtfsRoute('Cubao–Sta. Mesa', 'jeepney', [
        GtfsStop('Cubao', 14.6200, 121.0530),
        GtfsStop('Sta. Mesa', 14.5979, 121.0108),
      ]);
      expect(route.name, 'Cubao–Sta. Mesa');
      expect(route.mode, 'jeepney');
      expect(route.stops.map((s) => s.name), ['Cubao', 'Sta. Mesa']);
    });

    test('a match records both walk legs and the ride distance', () {
      const board = GtfsStop('Cubao', 14.6200, 121.0530);
      const alight = GtfsStop('Sta. Mesa', 14.5979, 121.0108);
      final match = GtfsRouteMatch(
        route: const GtfsRoute('R1', 'bus', [board, alight]),
        boardStop: board,
        alightStop: alight,
        walkToBoardM: 250,
        walkFromAlightM: 180,
        rideKm: 6.4,
      );
      expect(match.boardStop.name, 'Cubao');
      expect(match.alightStop.name, 'Sta. Mesa');
      expect(match.walkToBoardM, 250);
      expect(match.walkFromAlightM, 180);
      expect(match.rideKm, 6.4);
    });
  });
}
