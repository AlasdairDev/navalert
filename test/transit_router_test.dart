import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/services/transit_graph.dart';
import 'package:navalert/services/transit_router.dart';

/// Dijkstra multimodal router (R6).
///
/// The fixture is hand-built with a *known* answer so these tests assert the
/// router picked the right path — not merely that it returned something.
///
/// Geography (roughly 1.1 km per 0.01 degrees of latitude):
///
///   A(0.00) --routeN--> B(0.02) --routeN--> C(0.04)      [jeepney, direct]
///   A(0.00) --routeS--> S1     --routeS--> C(0.04)       [bus, parallel]
///   B has a second stop B2 ~150 m away, reachable on foot.
void main() {
  const lng = 121.0;

  Map<String, dynamic> route(String name, String mode, List<List> stops) =>
      {'n': name, 'm': mode, 's': stops};

  List<dynamic> fixture() => [
        // Direct jeepney A -> B -> C
        route('Jeep A-C', 'jeepney', [
          ['A', 14.60, lng],
          ['B', 14.62, lng],
          ['C', 14.64, lng],
        ]),
        // Parallel bus A -> S1 -> C (same endpoints, faster mode)
        route('Bus A-C', 'bus', [
          ['A', 14.60, lng],
          ['S1', 14.62, lng + 0.01],
          ['C', 14.64, lng],
        ]),
      ];

  TransitRouter build(List<dynamic> data) =>
      TransitRouter(TransitGraph.build(data));

  group('graph construction', () {
    test('collapses duplicate coordinates into shared hubs', () {
      final g = TransitGraph.build(fixture());
      // A and C are shared by both routes; S1 and B are unique.
      // 4 distinct corners => 4 hubs, and 6 ride nodes (3 stops x 2 routes).
      expect(g.hubCount, 4);
      expect(g.rideNodeCount, 6);
      expect(g.nodeCount, 10);
    });

    test('shared corners are what make a transfer reachable', () {
      final g = TransitGraph.build(fixture());
      // Hub A must expose a board edge onto both routes.
      final hubA = g.hubsNear(14.60, lng, 50).single;
      final node = g.hubNode(hubA);
      var boards = 0;
      for (var e = g.offsets[node]; e < g.offsets[node + 1]; e++) {
        if (g.edgeKind[e] == TransitGraph.kindBoard) boards++;
      }
      expect(boards, 2, reason: 'both routes board at A');
    });

    test('drops routes with fewer than two stops', () {
      final g = TransitGraph.build([
        route('Stub', 'jeepney', [
          ['X', 14.60, lng]
        ]),
        ...fixture(),
      ]);
      expect(g.routeName, isNot(contains('Stub')));
    });
  });

  group('routing correctness', () {
    test('finds a direct journey and reports its legs in order', () {
      final r = build(fixture());
      final journeys = r.plan(
          originLat: 14.60, originLng: lng, destLat: 14.64, destLng: lng);
      expect(journeys, isNotEmpty);
      final j = journeys.first;
      expect(j.legs.where((l) => !l.isWalk), isNotEmpty);
      expect(j.transfers, 0, reason: 'a direct route needs no transfer');
      expect(j.totalMinutes, greaterThan(0));
    });

    test('prefers the faster mode when both serve the same endpoints', () {
      final r = build(fixture());
      final j = r.plan(
          originLat: 14.60, originLng: lng, destLat: 14.64, destLng: lng);
      // Bus runs at 15 kph vs jeepney 11 kph over comparable distance, so the
      // time-optimal pass should board the bus.
      expect(j.first.legs.firstWhere((l) => !l.isWalk).mode, 'bus');
    });

    test('returns nothing when the origin is off-network', () {
      final r = build(fixture());
      // Baguio — far outside the fixture and beyond any access walk.
      final j = r.plan(
          originLat: 16.40, originLng: 120.59, destLat: 14.64, destLng: lng);
      expect(j, isEmpty, reason: 'caller must fall back to the estimate');
    });

    test('never exceeds the three-transfer cap', () {
      final r = build(fixture());
      for (final j in r.plan(
          originLat: 14.60, originLng: lng, destLat: 14.64, destLng: lng)) {
        expect(j.transfers, lessThanOrEqualTo(3));
        expect(j.boardings, lessThanOrEqualTo(TransitRouter.maxBoardings));
      }
    });
  });

  group('transfer penalty', () {
    // Two routes that only connect by transferring at M.
    List<dynamic> transferFixture() => [
          route('Leg 1', 'jeepney', [
            ['A', 14.60, lng],
            ['M', 14.62, lng],
          ]),
          route('Leg 2', 'jeepney', [
            ['M', 14.62, lng],
            ['Z', 14.64, lng],
          ]),
        ];

    test('a transfer journey is found when no direct route exists', () {
      final r = build(transferFixture());
      final j = r.plan(
          originLat: 14.60, originLng: lng, destLat: 14.64, destLng: lng);
      expect(j, isNotEmpty);
      expect(j.first.transfers, 1, reason: 'must change vehicles at M');
      expect(j.first.legs.where((l) => !l.isWalk).length, 2);
    });

    test('the penalty is actually charged into the journey time', () {
      final r = build(transferFixture());
      final j = r.plan(
          originLat: 14.60, originLng: lng, destLat: 14.64, destLng: lng);
      // Two boardings => two waits, and the second adds the transfer penalty.
      const floor = TransitRouter.boardingWaitMin * 2 +
          TransitRouter.transferPenaltyMin;
      expect(j.first.totalMinutes, greaterThanOrEqualTo(floor));
    });

    test('a direct route wins over a transfer route of similar length', () {
      // Direct jeepney A->Z alongside the two-leg option.
      final r = build([
        ...transferFixture(),
        route('Direct', 'jeepney', [
          ['A', 14.60, lng],
          ['Z', 14.64, lng],
        ]),
      ]);
      final j = r.plan(
          originLat: 14.60, originLng: lng, destLat: 14.64, destLng: lng);
      expect(j.first.transfers, 0,
          reason: 'the penalty should make one vehicle beat two');
    });
  });

  group('walking transfers', () {
    test('links two routes whose stops are a short walk apart', () {
      // P ends at 14.6200; Q starts at 14.6212 (~130 m away).
      final r = build([
        route('P', 'jeepney', [
          ['A', 14.60, lng],
          ['P-end', 14.6200, lng],
        ]),
        route('Q', 'jeepney', [
          ['Q-start', 14.6212, lng],
          ['Z', 14.64, lng],
        ]),
      ]);
      final j = r.plan(
          originLat: 14.60, originLng: lng, destLat: 14.64, destLng: lng);
      expect(j, isNotEmpty, reason: 'a 130 m walk should bridge the routes');
      expect(j.first.legs.any((l) => l.isWalk), isTrue);
      expect(j.first.transfers, 1);
    });

    test('does not link stops beyond the transfer walking radius', () {
      // 14.6200 -> 14.6250 is ~550 m, past the 250 m transfer limit.
      final r = build([
        route('P', 'jeepney', [
          ['A', 14.60, lng],
          ['P-end', 14.6200, lng],
        ]),
        route('Q', 'jeepney', [
          ['Q-start', 14.6250, lng],
          ['Z', 14.70, lng],
        ]),
      ]);
      final g = TransitGraph.build([
        route('P', 'jeepney', [
          ['A', 14.60, lng],
          ['P-end', 14.6200, lng],
        ]),
        route('Q', 'jeepney', [
          ['Q-start', 14.6250, lng],
          ['Z', 14.70, lng],
        ]),
      ]);
      var walks = 0;
      for (var e = 0; e < g.edgeKind.length; e++) {
        if (g.edgeKind[e] == TransitGraph.kindWalk) walks++;
      }
      expect(walks, 0, reason: '550 m is too far to be a transfer');
      // With no bridge the destination is unreachable by transit.
      final j = r.plan(
          originLat: 14.60, originLng: lng, destLat: 14.70, destLng: lng);
      expect(j.every((x) => x.transfers == 0), isTrue);
    });
  });

  group('mode preferences', () {
    test('respects a jeepney-only preference', () {
      final r = build(fixture());
      final j = r.plan(
        originLat: 14.60,
        originLng: lng,
        destLat: 14.64,
        destLng: lng,
        allowBus: false,
      );
      expect(j, isNotEmpty);
      for (final leg in j.expand((x) => x.legs)) {
        expect(leg.mode, isNot('bus'));
      }
    });

    test('respects a bus-only preference', () {
      final r = build(fixture());
      final j = r.plan(
        originLat: 14.60,
        originLng: lng,
        destLat: 14.64,
        destLng: lng,
        allowJeepney: false,
      );
      expect(j, isNotEmpty);
      for (final leg in j.expand((x) => x.legs)) {
        expect(leg.mode, isNot('jeepney'));
      }
    });

    test('disabling every mode yields no transit journey', () {
      final r = build(fixture());
      final j = r.plan(
        originLat: 14.60,
        originLng: lng,
        destLat: 14.64,
        destLng: lng,
        allowJeepney: false,
        allowBus: false,
      );
      expect(j.every((x) => x.boardings == 0), isTrue);
    });
  });
}
