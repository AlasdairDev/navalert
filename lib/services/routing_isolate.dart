import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'transit_graph.dart';
import 'transit_router.dart';

/// Serialisable request/response pair for the routing isolate. Only these
/// small objects cross the port — the graph itself never leaves the worker.
class RouteRequest {
  final double originLat, originLng, destLat, destLng;
  final bool allowJeepney, allowBus;
  const RouteRequest({
    required this.originLat,
    required this.originLng,
    required this.destLat,
    required this.destLng,
    required this.allowJeepney,
    required this.allowBus,
  });
}

/// Long-lived worker isolate that owns the transit graph (R6).
///
/// The graph is built once and kept, rather than rebuilt per search. Two
/// failure modes were designed out here:
///
///  * **Rebuild churn** — a `compute()` per search would re-decompress the
///    0.77 MB asset and re-materialise ~230K edges every time.
///  * **UI jank** — building and searching on the UI isolate would block
///    frames on a budget phone (Table 30 targets 4 GB RAM).
///
/// Spawned lazily on first search and disposed after [_idleTimeout], so a
/// rider who never opens the commute guide pays nothing.
class RoutingIsolate {
  RoutingIsolate._();
  static final RoutingIsolate instance = RoutingIsolate._();

  static const Duration _idleTimeout = Duration(minutes: 5);

  Isolate? _isolate;
  SendPort? _send;
  Completer<void>? _ready;
  Timer? _idle;
  int _seq = 0;
  final _pending = <int, Completer<List<PlannedJourney>>>{};
  ReceivePort? _receive;

  /// Plans journeys, or returns an empty list if routing is unavailable for
  /// any reason. Never throws: the commute guide must degrade to the
  /// synthetic estimate rather than fail, and must never block the alarm.
  Future<List<PlannedJourney>> plan(RouteRequest req) async {
    try {
      await _ensureStarted();
      final id = _seq++;
      final completer = Completer<List<PlannedJourney>>();
      _pending[id] = completer;
      _send!.send([
        id,
        req.originLat,
        req.originLng,
        req.destLat,
        req.destLng,
        req.allowJeepney,
        req.allowBus,
      ]);
      final result = await completer.future.timeout(
        const Duration(seconds: 12),
        onTimeout: () => const <PlannedJourney>[],
      );
      _touch();
      return result;
    } catch (e) {
      debugPrint('NavAlert: routing unavailable — $e');
      return const [];
    }
  }

  Future<void> _ensureStarted() async {
    if (_send != null) return;
    if (_ready != null) return _ready!.future;
    final ready = Completer<void>();
    _ready = ready;

    // Load and decompress on the main isolate's *IO*, then hand the decoded
    // structure over once. rootBundle is not available inside a bare isolate.
    final data = await rootBundle.load('assets/gtfs/routes.json.gz');
    final decoded = await compute(
        _decode, data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));

    final receive = ReceivePort();
    _receive = receive;
    _isolate = await Isolate.spawn(_entry, [receive.sendPort, decoded]);

    receive.listen((msg) {
      if (msg is SendPort) {
        _send = msg;
        if (!ready.isCompleted) ready.complete();
        return;
      }
      if (msg is List && msg.length == 2) {
        final id = msg[0] as int;
        final journeys = msg[1] as List<PlannedJourney>;
        _pending.remove(id)?.complete(journeys);
      }
    });

    await ready.future;
    _touch();
  }

  void _touch() {
    _idle?.cancel();
    _idle = Timer(_idleTimeout, dispose);
  }

  /// Releases the worker and its graph. Safe to call at any time; the next
  /// search simply respawns.
  void dispose() {
    _idle?.cancel();
    _idle = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receive?.close();
    _receive = null;
    _send = null;
    _ready = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(const []);
    }
    _pending.clear();
  }

  static List<dynamic> _decode(Uint8List gz) =>
      jsonDecode(utf8.decode(gzip.decode(gz))) as List<dynamic>;

  /// Worker entry point. Builds the graph once, then serves queries.
  static void _entry(List<dynamic> args) {
    final mainPort = args[0] as SendPort;
    final decoded = args[1] as List<dynamic>;

    final router = TransitRouter(TransitGraph.build(decoded));

    final port = ReceivePort();
    mainPort.send(port.sendPort);
    port.listen((msg) {
      final m = msg as List;
      final id = m[0] as int;
      List<PlannedJourney> out;
      try {
        out = router.plan(
          originLat: m[1] as double,
          originLng: m[2] as double,
          destLat: m[3] as double,
          destLng: m[4] as double,
          allowJeepney: m[5] as bool,
          allowBus: m[6] as bool,
        );
      } catch (_) {
        out = const [];
      }
      mainPort.send([id, out]);
    });
  }
}
