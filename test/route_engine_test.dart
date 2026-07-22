import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/models/guide_leg.dart';
import 'package:navalert/models/models.dart';
import 'package:navalert/services/gtfs_service.dart';
import 'package:navalert/services/route_engine.dart';

/// Commute guide engine — Requirement R6 and UC-4.
///
/// Fares are money the rider actually hands over, so the LTFRB matrix is
/// pinned to exact peso values rather than ranges.
void main() {
  final engine = RouteEngine();

  group('R6 — LTFRB fare matrix', () {
    test('jeepney: ₱13 for the first 4 km, then ₱1.80/km', () {
      expect(engine.jeepFare(0), 13.0);
      expect(engine.jeepFare(4), 13.0, reason: 'boundary is still base fare');
      expect(engine.jeepFare(10), closeTo(23.8, 0.001)); // 13 + 6 × 1.80
    });

    test('bus: ₱15 for the first 5 km, then ₱2.65/km', () {
      expect(engine.busFare(0), 15.0);
      expect(engine.busFare(5), 15.0);
      expect(engine.busFare(10), closeTo(28.25, 0.001)); // 15 + 5 × 2.65
    });

    test('UV Express: ₱15 for the first 4 km, then ₱2.20/km', () {
      expect(engine.uvFare(0), 15.0);
      expect(engine.uvFare(4), 15.0);
      expect(engine.uvFare(10), closeTo(28.2, 0.001)); // 15 + 6 × 2.20
    });

    test('fares rise monotonically with distance', () {
      var previous = 0.0;
      for (var km = 0.0; km <= 40; km += 0.5) {
        final fare = engine.jeepFare(km);
        expect(fare, greaterThanOrEqualTo(previous));
        previous = fare;
      }
    });

    test('a longer bus ride eventually costs more than the same jeepney ride',
        () {
      // Bus starts pricier and climbs faster — it should never be cheaper.
      for (final km in [1.0, 5.0, 10.0, 25.0]) {
        expect(engine.busFare(km), greaterThan(engine.jeepFare(km)));
      }
    });
  });

  group('haversine distance', () {
    test('identical points are zero apart', () {
      expect(engine.haversineKm(14.5979, 121.0108, 14.5979, 121.0108),
          closeTo(0, 0.0001));
    });

    test('one degree of latitude is ~111 km', () {
      expect(engine.haversineKm(0, 0, 1, 0), closeTo(111.19, 0.5));
    });

    test('is symmetric', () {
      final a = engine.haversineKm(14.5979, 121.0108, 14.6760, 121.0437);
      final b = engine.haversineKm(14.6760, 121.0437, 14.5979, 121.0108);
      expect(a, closeTo(b, 0.0001));
    });
  });

  group('R6 — suggestion building and mode priority', () {
    List<RouteSuggestion> build(TransportPreferences prefs,
            {double km = 10}) =>
        engine.buildSuggestions(
          tripId: 'trip-1',
          originLabel: 'PUP Sta. Mesa',
          destinationLabel: 'SM Megamall, Mandaluyong',
          distanceKm: km,
          prefs: prefs,
        );

    test('returns at most two ranked suggestions', () {
      final out = build(TransportPreferences());
      expect(out.length, lessThanOrEqualTo(2));
      expect(out, isNotEmpty);
      expect(out.map((s) => s.rank), [1, 2]);
    });

    test('honours a single enabled mode', () {
      final out = build(TransportPreferences(
          busEnabled: false, uvExpressEnabled: false, jeepneyEnabled: true));
      expect(out, hasLength(1));
      expect(out.single.transportSummary, contains('Jeep'));
      expect(out.single.transportSummary, isNot(contains('Bus')));
      expect(out.single.transportSummary, isNot(contains('UV')));
    });

    test('disabling every mode still returns options rather than nothing', () {
      // A rider who toggles everything off must not be left with an empty
      // commute guide — all modes are treated as available again.
      final out = build(TransportPreferences(
          busEnabled: false, uvExpressEnabled: false, jeepneyEnabled: false));
      expect(out, isNotEmpty);
    });

    test('never returns an empty guide for any preference combination', () {
      for (final bus in [true, false]) {
        for (final uv in [true, false]) {
          for (final jeep in [true, false]) {
            final out = build(TransportPreferences(
                busEnabled: bus, uvExpressEnabled: uv, jeepneyEnabled: jeep));
            expect(out, isNotEmpty,
                reason: 'bus=$bus uv=$uv jeep=$jeep produced no routes');
          }
        }
      }
    });

    test('every suggestion is walk-first and walk-last with numbered steps',
        () {
      for (final s in build(TransportPreferences())) {
        expect(s.steps.first.transportMode, 'walk');
        expect(s.steps.last.transportMode, 'walk');
        expect(s.steps.map((x) => x.stepNumber),
            List.generate(s.steps.length, (i) => i + 1));
        expect(s.totalFarePhp, greaterThan(0));
        expect(s.totalDurationMinutes, greaterThan(0));
        expect(s.tripId, 'trip-1');
      }
    });

    test('Figure 22 tags are only applied to suggestions actually shown', () {
      final out = build(TransportPreferences());
      const valid = {'Fastest', 'Cheapest', 'Longest', 'Costly'};
      final shownIds = out.map((s) => s.suggestionId).toSet();
      expect(shownIds, hasLength(out.length));

      for (final s in out) {
        for (final tag in [s.tagPrimary, s.tagSecondary]) {
          if (tag != null) expect(valid, contains(tag));
        }
      }
      // The quickest option on screen must carry the Fastest badge.
      final fastest = out.reduce((a, b) =>
          a.totalDurationMinutes <= b.totalDurationMinutes ? a : b);
      expect([fastest.tagPrimary, fastest.tagSecondary], contains('Fastest'));

      final cheapest =
          out.reduce((a, b) => a.totalFarePhp <= b.totalFarePhp ? a : b);
      expect([cheapest.tagPrimary, cheapest.tagSecondary], contains('Cheapest'));
    });

    test('a lone suggestion is both the fastest and the cheapest shown', () {
      final out = build(TransportPreferences(
          busEnabled: false, uvExpressEnabled: false, jeepneyEnabled: true));
      final tags = [out.single.tagPrimary, out.single.tagSecondary];
      expect(tags, contains('Fastest'));
      expect(tags, contains('Cheapest'));
      expect(tags, isNot(contains('Longest')),
          reason: 'nothing to be longer than');
    });

    test('a very short hop still produces a usable guide', () {
      final out = build(TransportPreferences(), km: 0.1);
      expect(out, isNotEmpty);
      expect(out.first.totalFarePhp, greaterThan(0));
    });

    test('synthetic guide legs never carry coordinates', () {
      // These routes are fractions of a straight line and their stops
      // ("… Terminal", "Transfer point") are fictional. Attaching coordinates
      // would let the guide claim the rider passed a place that does not exist.
      final legs = <String, List<GuideLeg>>{};
      final out = engine.buildSuggestions(
        tripId: 'trip-7',
        originLabel: 'PUP Sta. Mesa',
        destinationLabel: 'SM Megamall',
        distanceKm: 10,
        prefs: TransportPreferences(),
        legsOut: legs,
      );
      expect(legs, isNotEmpty);
      for (final s in out) {
        for (final leg in legs[s.suggestionId]!) {
          expect(leg.canAutoAdvance, isFalse);
          expect(leg.endLat, isNull);
          expect(leg.endLng, isNull);
        }
      }
    });
  });

  group('R6 — suggestions from real GTFS matches', () {
    GtfsRouteMatch match(String mode, double rideKm) => GtfsRouteMatch(
          route: GtfsRoute('Cubao–Sta. Mesa', mode, const [
            GtfsStop('Cubao', 14.6200, 121.0530),
            GtfsStop('Sta. Mesa', 14.5979, 121.0108),
          ]),
          boardStop: const GtfsStop('Cubao', 14.6200, 121.0530),
          alightStop: const GtfsStop('Sta. Mesa', 14.5979, 121.0108),
          walkToBoardM: 300,
          walkFromAlightM: 200,
          rideKm: rideKm,
        );

    test('names the real route and charges the jeepney fare on ride distance',
        () {
      final out = engine.buildFromGtfs(
        tripId: 'trip-2',
        destinationLabel: 'PUP Sta. Mesa',
        matches: [match('jeepney', 10)],
      );
      expect(out, hasLength(1));
      final s = out.single;
      expect(s.routeLabel, 'Jeep: Cubao–Sta. Mesa');
      expect(s.transportSummary, 'Walk + Jeep');
      // jeepFare(10) = 23.80, rounded up to the nearest ₱0.25 => 24.00
      expect(s.totalFarePhp, closeTo(24.0, 0.001));
      expect(s.steps.map((x) => x.transportMode), ['walk', 'jeepney', 'walk']);
      expect(s.steps[1].fromStop, 'Cubao');
      expect(s.steps[1].toStop, 'Sta. Mesa');
    });

    test('uses the bus fare and noun for bus routes', () {
      final out = engine.buildFromGtfs(
        tripId: 'trip-3',
        destinationLabel: 'PUP Sta. Mesa',
        matches: [match('bus', 10)],
      );
      final s = out.single;
      expect(s.routeLabel, startsWith('Bus:'));
      // busFare(10) = 28.25, already on a ₱0.25 boundary.
      expect(s.totalFarePhp, closeTo(28.25, 0.001));
    });

    test('no GTFS match yields no suggestions so the caller can fall back', () {
      expect(
        engine.buildFromGtfs(
            tripId: 't', destinationLabel: 'X', matches: const []),
        isEmpty,
      );
    });

    test('emits guide legs carrying the real board/alight coordinates', () {
      final legs = <String, List<GuideLeg>>{};
      final out = engine.buildFromGtfs(
        tripId: 'trip-5',
        destinationLabel: 'PUP Sta. Mesa',
        matches: [match('jeepney', 8)],
        legsOut: legs,
      );
      final mine = legs[out.single.suggestionId]!;
      expect(mine, hasLength(3));

      // Walk-to-board ends at the boarding stop; the ride ends at the alight
      // stop. Both come from the feed and drive automatic advancement.
      expect(mine[0].canAutoAdvance, isTrue);
      expect(mine[0].endLat, 14.6200);
      expect(mine[0].endLng, 121.0530);
      expect(mine[1].canAutoAdvance, isTrue);
      expect(mine[1].endLat, 14.5979);
      expect(mine[1].endLng, 121.0108);

      // The final walk ends at the destination, whose coordinates are not
      // passed in here, so it stays manual.
      expect(mine[2].canAutoAdvance, isFalse);
    });

    test('legs are optional — omitting legsOut changes nothing', () {
      final out = engine.buildFromGtfs(
        tripId: 'trip-6',
        destinationLabel: 'PUP Sta. Mesa',
        matches: [match('jeepney', 8)],
      );
      expect(out, hasLength(1));
    });

    test('keeps at most two matches and ranks them', () {
      final out = engine.buildFromGtfs(
        tripId: 'trip-4',
        destinationLabel: 'PUP Sta. Mesa',
        matches: [match('jeepney', 4), match('bus', 12), match('jeepney', 9)],
      );
      expect(out.length, lessThanOrEqualTo(2));
      expect(out.map((s) => s.rank), [1, 2]);
      expect(out.first.totalDurationMinutes,
          lessThanOrEqualTo(out.last.totalDurationMinutes));
    });
  });
}
