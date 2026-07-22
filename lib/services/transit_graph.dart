import 'dart:math' as math;
import 'dart:typed_data';

/// Compact routing graph over the bundled Metro Manila GTFS feed (R6).
///
/// Two node kinds, because a stop-only graph cannot price a trip correctly —
/// jeepney fare is ₱13 for the first 4 km *of each boarding*, so cost depends
/// on where the rider boarded and whether they stayed aboard:
///
///  * **Ride node** `(stop, route)` — aboard route R at stop S.
///  * **Hub node** `(stop)` — standing at stop S, not aboard anything.
///
/// Routing transfers through a hub keeps the edge count linear. Connecting
/// every `(S,R1) → (S,R2)` pair directly is O(k²) per stop — roughly 1.15M
/// edges on this feed, and far worse at busy hubs. Via hubs it is O(k),
/// landing at ~230K edges.
///
/// Adjacency is stored as flat CSR typed arrays rather than object lists: an
/// object per edge would box ~230K allocations onto the heap, which is exactly
/// the pressure a 4 GB budget phone (Table 30) cannot absorb.
class TransitGraph {
  TransitGraph._({
    required this.nodeCount,
    required this.hubCount,
    required this.offsets,
    required this.targets,
    required this.edgeKm,
    required this.edgeKind,
    required this.nodeRoute,
    required this.nodeStop,
    required this.hubLat,
    required this.hubLng,
    required this.hubName,
    required this.routeName,
    required this.routeMode,
  });

  /// Edge kinds. Weights are derived per search pass, not stored per kind.
  static const int kindRide = 0;
  static const int kindAlight = 1;
  static const int kindBoard = 2;
  static const int kindWalk = 3;

  /// Maximum walking distance between two stops for a transfer (metres).
  static const double transferWalkM = 250;

  final int nodeCount;
  final int hubCount;

  /// CSR adjacency: edges of node `i` are `offsets[i] ..< offsets[i + 1]`.
  final Int32List offsets;
  final Int32List targets;
  final Float32List edgeKm;
  final Uint8List edgeKind;

  /// Ride nodes are `0 ..< nodeCount - hubCount`; hubs occupy the tail.
  /// For a ride node, the route and hub it belongs to.
  final Int32List nodeRoute;
  final Int32List nodeStop;

  final Float64List hubLat;
  final Float64List hubLng;
  final List<String> hubName;
  final List<String> routeName;

  /// 0 = jeepney, 1 = bus. Kept as an int so it stays in a typed array.
  final Uint8List routeMode;

  int get rideNodeCount => nodeCount - hubCount;

  /// Hub node id for hub index [h].
  int hubNode(int h) => rideNodeCount + h;

  /// Hub index for a hub node id.
  int hubIndexOf(int node) => node - rideNodeCount;

  bool isHub(int node) => node >= rideNodeCount;

  /// Builds the graph from the decoded GTFS payload.
  ///
  /// [decoded] is the raw asset structure: a list of
  /// `{'n': routeName, 'm': mode, 's': [[stopName, lat, lng], ...]}`.
  factory TransitGraph.build(List<dynamic> decoded) {
    // ---- 1. Collapse stop-points to unique coordinates ------------------
    // 74,018 stop-points reduce to ~4,781 real corners. This dedup is what
    // makes transfers possible at all: the same corner on two routes would
    // otherwise never connect.
    final hubIndex = <int, int>{};
    final hubLatB = <double>[];
    final hubLngB = <double>[];
    final hubNameB = <String>[];

    int internHub(String name, double lat, double lng) {
      // 1e-5 degrees ≈ 1.1 m — tight enough to keep distinct corners apart,
      // loose enough to merge the same corner written with float jitter.
      final key = (((lat * 100000).round() & 0xFFFFFFF) << 28) ^
          ((lng * 100000).round() & 0xFFFFFFF);
      final existing = hubIndex[key];
      if (existing != null) return existing;
      final id = hubLatB.length;
      hubIndex[key] = id;
      hubLatB.add(lat);
      hubLngB.add(lng);
      hubNameB.add(name);
      return id;
    }

    final routeNameB = <String>[];
    final routeModeB = <int>[];
    // Per route, the ordered hub indices it serves.
    final routeHubs = <List<int>>[];

    for (final raw in decoded) {
      final m = raw as Map<String, dynamic>;
      final stops = m['s'] as List;
      if (stops.length < 2) continue; // a 1-stop route cannot carry anyone
      final hubs = <int>[];
      for (final s in stops) {
        final t = s as List;
        hubs.add(internHub(
            t[0] as String, (t[1] as num).toDouble(), (t[2] as num).toDouble()));
      }
      routeNameB.add(m['n'] as String);
      routeModeB.add((m['m'] as String) == 'bus' ? 1 : 0);
      routeHubs.add(hubs);
    }

    final hubCount = hubLatB.length;

    // ---- 2. Allocate ride nodes -----------------------------------------
    final nodeRouteB = <int>[];
    final nodeStopB = <int>[];
    // rideNodeOf[route][position] -> node id
    final rideNodeOf = <List<int>>[];
    // Ride nodes present at each hub, for board/alight wiring.
    final nodesAtHub = List.generate(hubCount, (_) => <int>[]);

    for (var r = 0; r < routeHubs.length; r++) {
      final hubs = routeHubs[r];
      final ids = List<int>.filled(hubs.length, 0);
      for (var i = 0; i < hubs.length; i++) {
        final id = nodeRouteB.length;
        nodeRouteB.add(r);
        nodeStopB.add(hubs[i]);
        ids[i] = id;
        nodesAtHub[hubs[i]].add(id);
      }
      rideNodeOf.add(ids);
    }

    final rideNodeCount = nodeRouteB.length;
    final nodeCount = rideNodeCount + hubCount;

    // ---- 3. Build edge lists --------------------------------------------
    final adj = List.generate(nodeCount, (_) => <int>[]);
    final adjKm = List.generate(nodeCount, (_) => <double>[]);
    final adjKind = List.generate(nodeCount, (_) => <int>[]);

    void addEdge(int from, int to, double km, int kind) {
      adj[from].add(to);
      adjKm[from].add(km);
      adjKind[from].add(kind);
    }

    // Ride edges: consecutive stops along a route, one direction only.
    // The feed lists each direction as its own route, so adding reverse
    // edges here would invent trips that do not run.
    for (var r = 0; r < rideNodeOf.length; r++) {
      final ids = rideNodeOf[r];
      final hubs = routeHubs[r];
      for (var i = 0; i + 1 < ids.length; i++) {
        final km = _haversineKm(hubLatB[hubs[i]], hubLngB[hubs[i]],
            hubLatB[hubs[i + 1]], hubLngB[hubs[i + 1]]);
        addEdge(ids[i], ids[i + 1], km, kindRide);
      }
    }

    // Alight (free) and board (costed) edges through each hub.
    for (var h = 0; h < hubCount; h++) {
      final hub = rideNodeCount + h;
      for (final node in nodesAtHub[h]) {
        addEdge(node, hub, 0, kindAlight);
        addEdge(hub, node, 0, kindBoard);
      }
    }

    // Walk edges between nearby hubs, found by grid bucketing rather than
    // an O(n²) sweep over 4,781 hubs.
    const cell = 0.0025; // ~275 m, comfortably wider than transferWalkM
    final grid = <int, List<int>>{};
    for (var h = 0; h < hubCount; h++) {
      final key = ((hubLatB[h] / cell).floor() << 20) ^
          (hubLngB[h] / cell).floor();
      (grid[key] ??= <int>[]).add(h);
    }
    for (var h = 0; h < hubCount; h++) {
      final cx = (hubLatB[h] / cell).floor();
      final cy = (hubLngB[h] / cell).floor();
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          final bucket = grid[((cx + dx) << 20) ^ (cy + dy)];
          if (bucket == null) continue;
          for (final o in bucket) {
            if (o == h) continue;
            final km = _haversineKm(
                hubLatB[h], hubLngB[h], hubLatB[o], hubLngB[o]);
            if (km * 1000 > transferWalkM) continue;
            addEdge(rideNodeCount + h, rideNodeCount + o, km, kindWalk);
          }
        }
      }
    }

    // ---- 4. Flatten to CSR ----------------------------------------------
    var total = 0;
    for (final e in adj) {
      total += e.length;
    }
    final offsets = Int32List(nodeCount + 1);
    final targets = Int32List(total);
    final edgeKm = Float32List(total);
    final edgeKind = Uint8List(total);
    var cursor = 0;
    for (var n = 0; n < nodeCount; n++) {
      offsets[n] = cursor;
      final e = adj[n];
      for (var i = 0; i < e.length; i++) {
        targets[cursor] = e[i];
        edgeKm[cursor] = adjKm[n][i];
        edgeKind[cursor] = adjKind[n][i];
        cursor++;
      }
    }
    offsets[nodeCount] = cursor;

    return TransitGraph._(
      nodeCount: nodeCount,
      hubCount: hubCount,
      offsets: offsets,
      targets: targets,
      edgeKm: edgeKm,
      edgeKind: edgeKind,
      nodeRoute: Int32List.fromList(nodeRouteB),
      nodeStop: Int32List.fromList(nodeStopB),
      hubLat: Float64List.fromList(hubLatB),
      hubLng: Float64List.fromList(hubLngB),
      hubName: hubNameB,
      routeName: routeNameB,
      routeMode: Uint8List.fromList(routeModeB),
    );
  }

  /// Hubs within [maxM] metres of a point, nearest first. Used to attach the
  /// rider's origin and destination to the network.
  List<int> hubsNear(double lat, double lng, double maxM, {int limit = 24}) {
    final found = <int>[];
    final dist = <double>[];
    for (var h = 0; h < hubCount; h++) {
      final m = _haversineKm(lat, lng, hubLat[h], hubLng[h]) * 1000;
      if (m <= maxM) {
        found.add(h);
        dist.add(m);
      }
    }
    final order = List<int>.generate(found.length, (i) => i)
      ..sort((a, b) => dist[a].compareTo(dist[b]));
    return [for (final i in order.take(limit)) found[i]];
  }

  double distanceM(double lat1, double lng1, double lat2, double lng2) =>
      _haversineKm(lat1, lng1, lat2, lng2) * 1000;
}

double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLon = (lon2 - lon1) * math.pi / 180.0;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}
