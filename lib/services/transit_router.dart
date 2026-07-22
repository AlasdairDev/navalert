import 'dart:typed_data';

import 'transit_graph.dart';

/// One contiguous leg of a planned journey.
class PlannedLeg {
  /// null for a walking leg.
  final int? routeIndex;
  final String? routeName;

  /// 'walk' | 'jeepney' | 'bus'
  final String mode;
  final String fromStop;
  final String toStop;
  final double fromLat, fromLng, toLat, toLng;
  final double km;
  final double minutes;

  const PlannedLeg({
    this.routeIndex,
    this.routeName,
    required this.mode,
    required this.fromStop,
    required this.toStop,
    required this.fromLat,
    required this.fromLng,
    required this.toLat,
    required this.toLng,
    required this.km,
    required this.minutes,
  });

  bool get isWalk => mode == 'walk';
}

/// A complete journey. Fare is deliberately absent — it is computed exactly by
/// RouteEngine from the LTFRB matrix once the path is known, never estimated
/// here (see the fare note on [TransitRouter]).
class PlannedJourney {
  final List<PlannedLeg> legs;
  final double totalMinutes;

  const PlannedJourney({required this.legs, required this.totalMinutes});

  int get boardings => legs.where((l) => !l.isWalk).length;
  int get transfers => boardings > 0 ? boardings - 1 : 0;

  /// Identity used to drop duplicate paths returned by the two passes.
  String get signature =>
      legs.map((l) => '${l.mode}:${l.routeIndex ?? ''}:${l.toStop}').join('>');
}

/// Dijkstra over [TransitGraph], as specified for R6.
///
/// **Two passes.** Figure 22 needs genuinely differently-ranked Fastest and
/// Cheapest options, and fare cannot be recovered from a time-optimal path.
/// Pass 1 minimises travel time; pass 2 minimises a fare proxy.
///
/// **Why the fare weight is a proxy.** Real fare is state-dependent — ₱13
/// covers the *first 4 km* of each boarding — so it does not decompose into
/// fixed edge weights. The proxy charges base fare on boarding plus a flat
/// per-km rate, which is monotonic and non-negative, keeping Dijkstra valid.
/// The fare actually shown to the rider is computed exactly afterwards from
/// the chosen path. A proxy pass can therefore pick a marginally sub-optimal
/// path, but it can never display a wrong price.
///
/// **Boarding count lives in the search state.** Capping at 4 boardings
/// (3 transfers, matching the paper's three-modes finding) by pruning would
/// break optimality; encoding it in the label keeps the result provably
/// optimal within the cap.
class TransitRouter {
  TransitRouter(this.graph);

  final TransitGraph graph;

  // Average in-traffic speeds, matching RouteEngine.
  static const double jeepKph = 11.0;
  static const double busKph = 15.0;
  static const double walkKph = 4.5;

  /// Headway/queueing buffer applied on every boarding.
  static const double boardingWaitMin = 7.0;

  /// Charged on every boarding *after the first*. Jeon et al. (2018) found
  /// routers that ignore transfer penalties return paths passengers reject.
  static const double transferPenaltyMin = 5.0;

  static const double jeepBase = 13.0, jeepPerKm = 1.80;
  static const double busBase = 15.0, busPerKm = 2.65;

  /// 4 boardings = 3 transfers.
  static const int maxBoardings = 4;

  /// How far the rider will walk to reach the network at either end.
  static const double accessWalkM = 800;

  /// Plans up to two journeys: fastest first, then cheapest if it differs.
  List<PlannedJourney> plan({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
    bool allowJeepney = true,
    bool allowBus = true,
  }) {
    final origins = graph.hubsNear(originLat, originLng, accessWalkM);
    final dests = graph.hubsNear(destLat, destLng, accessWalkM);
    if (origins.isEmpty || dests.isEmpty) return const [];

    final destSet = <int>{for (final h in dests) h};

    final out = <PlannedJourney>[];
    final seen = <String>{};
    for (final byFare in [false, true]) {
      final j = _search(
        origins: origins,
        originLat: originLat,
        originLng: originLng,
        destSet: destSet,
        destLat: destLat,
        destLng: destLng,
        byFare: byFare,
        allowJeepney: allowJeepney,
        allowBus: allowBus,
      );
      if (j != null && seen.add(j.signature)) out.add(j);
    }
    return out;
  }

  PlannedJourney? _search({
    required List<int> origins,
    required double originLat,
    required double originLng,
    required Set<int> destSet,
    required double destLat,
    required double destLng,
    required bool byFare,
    required bool allowJeepney,
    required bool allowBus,
  }) {
    final g = graph;
    final states = g.nodeCount * (maxBoardings + 1);
    // Float64, deliberately. Costs are doubles; storing them in a Float32List
    // truncates, and the stale-entry guard below then sees the popped cost as
    // *greater* than the value it just wrote and discards the settled node —
    // silently losing most of the graph. ~3 MB at NCR scale is worth paying.
    final dist = Float64List(states)
      ..fillRange(0, states, double.infinity);
    final prev = Int32List(states)..fillRange(0, states, -1);
    final prevEdge = Int32List(states)..fillRange(0, states, -1);

    final heap = _MinHeap();

    // Seed: walk from the rider's position to each nearby hub.
    for (final h in origins) {
      final node = g.hubNode(h);
      final m = g.distanceM(originLat, originLng, g.hubLat[h], g.hubLng[h]);
      final cost = byFare
          ? _tieBreak(m / 1000 / walkKph * 60)
          : m / 1000 / walkKph * 60;
      final s = node * (maxBoardings + 1);
      if (cost < dist[s]) {
        dist[s] = cost;
        heap.push(cost, s);
      }
    }

    var bestState = -1;
    var bestCost = double.infinity;

    while (heap.isNotEmpty) {
      final s = heap.pop();
      final d = heap.lastCost;
      if (d > dist[s]) continue; // stale heap entry

      final node = s ~/ (maxBoardings + 1);
      final boardings = s % (maxBoardings + 1);

      if (g.isHub(node) && destSet.contains(g.hubIndexOf(node))) {
        final h = g.hubIndexOf(node);
        final tail = g.distanceM(g.hubLat[h], g.hubLng[h], destLat, destLng);
        final total = d +
            (byFare
                ? _tieBreak(tail / 1000 / walkKph * 60)
                : tail / 1000 / walkKph * 60);
        if (total < bestCost) {
          bestCost = total;
          bestState = s;
        }
        // Keep scanning: a farther hub may still yield a cheaper total.
      }

      if (d > bestCost) continue; // cannot improve

      for (var e = g.offsets[node]; e < g.offsets[node + 1]; e++) {
        final kind = g.edgeKind[e];
        final to = g.targets[e];
        var nextBoardings = boardings;

        if (kind == TransitGraph.kindBoard) {
          if (boardings >= maxBoardings) continue;
          final mode = g.routeMode[g.nodeRoute[to]];
          if (mode == 0 && !allowJeepney) continue;
          if (mode == 1 && !allowBus) continue;
          nextBoardings = boardings + 1;
        }

        final w = _weight(e, kind, to, byFare, boardings);
        final nd = d + w;
        final ns = to * (maxBoardings + 1) + nextBoardings;
        if (nd < dist[ns]) {
          dist[ns] = nd;
          prev[ns] = s;
          prevEdge[ns] = e;
          heap.push(nd, ns);
        }
      }
    }

    if (bestState < 0) return null;
    return _reconstruct(bestState, prev, prevEdge, originLat, originLng,
        destLat, destLng);
  }

  /// Fare-pass costs carry a small time term; without it a fare-optimal search
  /// happily returns a two-hour walk to save one peso.
  double _tieBreak(double minutes) => minutes * 0.05;

  double _weight(int e, int kind, int to, bool byFare, int boardings) {
    final km = graph.edgeKm[e];
    switch (kind) {
      case TransitGraph.kindRide:
        final mode = graph.routeMode[graph.nodeRoute[to]];
        final kph = mode == 1 ? busKph : jeepKph;
        final minutes = km / kph * 60;
        return byFare
            ? km * (mode == 1 ? busPerKm : jeepPerKm) + _tieBreak(minutes)
            : minutes;
      case TransitGraph.kindAlight:
        return 0;
      case TransitGraph.kindBoard:
        final mode = graph.routeMode[graph.nodeRoute[to]];
        final minutes =
            boardingWaitMin + (boardings > 0 ? transferPenaltyMin : 0);
        return byFare
            ? (mode == 1 ? busBase : jeepBase) + _tieBreak(minutes)
            : minutes;
      default: // walk
        final minutes = km / walkKph * 60;
        return byFare ? _tieBreak(minutes) : minutes;
    }
  }

  PlannedJourney _reconstruct(int endState, Int32List prev, Int32List prevEdge,
      double originLat, double originLng, double destLat, double destLng) {
    final g = graph;
    // Walk the predecessor chain back to the seed.
    final edges = <int>[];
    var s = endState;
    while (prevEdge[s] >= 0) {
      edges.add(prevEdge[s]);
      s = prev[s];
    }
    final ordered = edges.reversed.toList();

    final legs = <PlannedLeg>[];
    var total = 0.0;

    // Access walk from the rider to the first hub.
    final firstHub = g.hubIndexOf(s ~/ (maxBoardings + 1));
    final accessM =
        g.distanceM(originLat, originLng, g.hubLat[firstHub], g.hubLng[firstHub]);
    if (accessM > 30) {
      final mins = accessM / 1000 / walkKph * 60;
      total += mins;
      legs.add(PlannedLeg(
        mode: 'walk',
        fromStop: 'Your location',
        toStop: g.hubName[firstHub],
        fromLat: originLat,
        fromLng: originLng,
        toLat: g.hubLat[firstHub],
        toLng: g.hubLng[firstHub],
        km: accessM / 1000,
        minutes: mins,
      ));
    }

    // Merge consecutive ride edges on the same route into one leg — the rider
    // boards once and stays aboard, which is also what the fare depends on.
    int? runRoute;
    var runKm = 0.0;
    var runMin = 0.0;
    int? runFromHub;
    int? runToHub;

    void flushRide() {
      final r = runRoute;
      final from = runFromHub;
      final to = runToHub;
      if (r == null || from == null || to == null) return;
      // A boarding that never moved is not a leg the rider can ride.
      if (from == to && runKm == 0) {
        runRoute = null;
        runKm = 0;
        runMin = 0;
        return;
      }
      total += runMin;
      legs.add(PlannedLeg(
        routeIndex: r,
        routeName: g.routeName[r],
        mode: g.routeMode[r] == 1 ? 'bus' : 'jeepney',
        fromStop: g.hubName[from],
        toStop: g.hubName[to],
        fromLat: g.hubLat[from],
        fromLng: g.hubLng[from],
        toLat: g.hubLat[to],
        toLng: g.hubLng[to],
        km: runKm,
        minutes: runMin,
      ));
      runRoute = null;
      runKm = 0;
      runMin = 0;
    }

    for (final e in ordered) {
      final kind = g.edgeKind[e];
      final to = g.targets[e];
      final km = g.edgeKm[e];
      if (kind == TransitGraph.kindRide) {
        final r = g.nodeRoute[to];
        // A ride edge is always preceded by a board edge on the same route,
        // which already opened the run and recorded where it started.
        final kph = g.routeMode[r] == 1 ? busKph : jeepKph;
        runKm += km;
        runMin += km / kph * 60;
        runToHub = g.nodeStop[to];
      } else if (kind == TransitGraph.kindBoard) {
        flushRide();
        final r = g.nodeRoute[to];
        runRoute = r;
        runFromHub = g.nodeStop[to];
        runToHub = g.nodeStop[to];
        runKm = 0;
        runMin = boardingWaitMin +
            (legs.any((l) => !l.isWalk) ? transferPenaltyMin : 0);
      } else if (kind == TransitGraph.kindWalk) {
        flushRide();
        final fromHub = g.hubIndexOf(_sourceOfWalk(e));
        final toHub = g.hubIndexOf(to);
        final mins = km / walkKph * 60;
        total += mins;
        legs.add(PlannedLeg(
          mode: 'walk',
          fromStop: g.hubName[fromHub],
          toStop: g.hubName[toHub],
          fromLat: g.hubLat[fromHub],
          fromLng: g.hubLng[fromHub],
          toLat: g.hubLat[toHub],
          toLng: g.hubLng[toHub],
          km: km,
          minutes: mins,
        ));
      }
      // kindAlight contributes nothing.
    }
    flushRide();

    // Final walk to the destination.
    if (legs.isNotEmpty) {
      final last = legs.last;
      final tailM = g.distanceM(last.toLat, last.toLng, destLat, destLng);
      if (tailM > 30) {
        final mins = tailM / 1000 / walkKph * 60;
        total += mins;
        legs.add(PlannedLeg(
          mode: 'walk',
          fromStop: last.toStop,
          toStop: 'Destination',
          fromLat: last.toLat,
          fromLng: last.toLng,
          toLat: destLat,
          toLng: destLng,
          km: tailM / 1000,
          minutes: mins,
        ));
      }
    }

    return PlannedJourney(legs: legs, totalMinutes: total);
  }

  /// CSR stores targets, not sources; recover the source by binary-searching
  /// the offsets array for the row that owns edge [e].
  int _sourceOfWalk(int e) {
    var lo = 0, hi = graph.nodeCount - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (graph.offsets[mid] <= e) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}

/// Binary min-heap over (cost, state). A plain sorted list would turn each
/// pop into an O(n) shift across ~394K states.
class _MinHeap {
  final _costs = <double>[];
  final _items = <int>[];
  double lastCost = 0;

  bool get isNotEmpty => _items.isNotEmpty;

  void push(double cost, int item) {
    _costs.add(cost);
    _items.add(item);
    var i = _items.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_costs[parent] <= _costs[i]) break;
      _swap(i, parent);
      i = parent;
    }
  }

  int pop() {
    final topItem = _items[0];
    lastCost = _costs[0];
    final lastIdx = _items.length - 1;
    _items[0] = _items[lastIdx];
    _costs[0] = _costs[lastIdx];
    _items.removeLast();
    _costs.removeLast();
    var i = 0;
    final n = _items.length;
    while (true) {
      final l = 2 * i + 1, r = 2 * i + 2;
      var smallest = i;
      if (l < n && _costs[l] < _costs[smallest]) smallest = l;
      if (r < n && _costs[r] < _costs[smallest]) smallest = r;
      if (smallest == i) break;
      _swap(i, smallest);
      i = smallest;
    }
    return topItem;
  }

  void _swap(int a, int b) {
    final ti = _items[a];
    _items[a] = _items[b];
    _items[b] = ti;
    final tc = _costs[a];
    _costs[a] = _costs[b];
    _costs[b] = tc;
  }
}
