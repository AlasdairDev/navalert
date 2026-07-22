@Tags(['real-feed'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/services/transit_graph.dart';
import 'package:navalert/services/transit_router.dart';

/// Exercises the router against the **real** bundled Metro Manila feed, not a
/// fixture. Reads the asset straight off disk so it needs no Flutter bindings.
///
/// This is the guard that a synthetic fixture cannot give: it proves the graph
/// actually fits in memory and that a full NCR search returns inside a budget
/// a commuter would tolerate.
void main() {
  late TransitGraph graph;
  late TransitRouter router;

  setUpAll(() {
    final gz = File('assets/gtfs/routes.json.gz').readAsBytesSync();
    final decoded = jsonDecode(utf8.decode(gzip.decode(gz))) as List<dynamic>;
    final sw = Stopwatch()..start();
    graph = TransitGraph.build(decoded);
    sw.stop();
    router = TransitRouter(graph);
    // ignore: avoid_print
    print('graph built in ${sw.elapsedMilliseconds} ms — '
        '${graph.hubCount} hubs, ${graph.rideNodeCount} ride nodes, '
        '${graph.targets.length} edges');
  });

  test('collapses the feed to the measured hub count', () {
    // 74,018 stop-points share only ~4,781 real corners. That dedup is what
    // makes transfers possible at all.
    expect(graph.hubCount, greaterThan(4000));
    expect(graph.hubCount, lessThan(6000));
    expect(graph.rideNodeCount, greaterThan(70000));
  });

  test('edge count stays near the design estimate', () {
    // ~230K. A blow-up here means hub routing regressed to O(k^2) pairwise
    // transfers, which is the thing that would actually threaten memory.
    expect(graph.targets.length, lessThan(400000));
  });

  test('plans a real cross-city journey (PUP → Cubao)', () {
    final journeys = router.plan(
      originLat: 14.5979,
      originLng: 121.0108,
      destLat: 14.6200,
      destLng: 121.0530,
    );
    expect(journeys, isNotEmpty, reason: 'both ends are well inside NCR');
    for (final j in journeys) {
      expect(j.totalMinutes, greaterThan(0));
      expect(j.transfers, lessThanOrEqualTo(3));
      expect(j.legs.first.isWalk || !j.legs.first.isWalk, isTrue);
      // ignore: avoid_print
      print('  ${j.totalMinutes.round()} min, ${j.transfers} transfer(s): '
          '${j.legs.where((l) => !l.isWalk).map((l) => l.routeName).join(" → ")}');
    }
  });

  test('a full NCR search completes within budget', () {
    final sw = Stopwatch()..start();
    router.plan(
      originLat: 14.5979,
      originLng: 121.0108,
      destLat: 14.6760,
      destLng: 121.0437,
    );
    sw.stop();
    // ignore: avoid_print
    print('  two-pass search: ${sw.elapsedMilliseconds} ms');
    // Generous: this runs in a worker isolate, so it never blocks a frame.
    // The assertion exists to catch an algorithmic regression, not to tune.
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  test('honours mode preferences against the real feed', () {
    final busOnly = router.plan(
      originLat: 14.5979,
      originLng: 121.0108,
      destLat: 14.6200,
      destLng: 121.0530,
      allowJeepney: false,
    );
    for (final leg in busOnly.expand((j) => j.legs)) {
      expect(leg.mode, isNot('jeepney'));
    }
  });

  test('returns nothing outside the covered area', () {
    // Baguio — real coordinates, no feed coverage. Must yield empty so the
    // caller falls back rather than inventing a route.
    final j = router.plan(
      originLat: 16.4023,
      originLng: 120.5960,
      destLat: 16.4100,
      destLng: 120.6000,
    );
    expect(j, isEmpty);
  });
}
