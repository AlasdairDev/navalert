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
  /// Receives the worker's exit/error signal — see [_startWorker].
  ReceivePort? _died;

  /// Plans journeys, or returns an empty list if routing is unavailable for
  /// any reason. Never throws: the commute guide must degrade to the
  /// synthetic estimate rather than fail, and must never block the alarm.
  /// Ceiling on cold start: asset load + gzip/JSON decode + isolate spawn +
  /// the ~230K-edge graph build. Generous enough for a budget phone (Table 30),
  /// bounded so it can never become an infinite wait — see [_ensureStarted].
  static const Duration _startupTimeout = Duration(seconds: 25);

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

  // DO NOT MODIFY LOGIC: every exit from this method must be BOUNDED, and a
  // failed start must leave the service retryable.
  //
  // This was the app's worst hang. `plan()` time-boxes the query but awaited
  // this method unbounded, and `ready` is completed only by the worker sending
  // its SendPort — which happens AFTER TransitGraph.build() materialises ~230K
  // edges inside the isolate. If that build threw (or the OS killed the worker
  // on a low-memory device), the isolate died before ever sending the port, so
  // `ready.future` never completed and never errored. `plan()` therefore hung
  // forever, and because `_ready` was left non-null every later search returned
  // that same dead future — the search → route path stayed bricked for the rest
  // of the session, behind a barrierDismissible:false spinner the rider could
  // not escape. The whole point of `plan()` is to degrade to the synthetic
  // estimate; it cannot do that if it never returns.
  Future<void> _ensureStarted() async {
    if (_send != null) return;
    if (_ready != null) return _ready!.future;
    final ready = Completer<void>();
    _ready = ready;
    try {
      await _startWorker(ready).timeout(_startupTimeout);
      _touch();
    } catch (e) {
      // Tear the half-built worker down and clear _ready, so the NEXT search
      // gets a clean attempt instead of re-awaiting a completer that will never
      // fire. Without this reset the failure was permanent, not transient.
      dispose();
      rethrow; // plan() catches and falls back to the synthetic guide.
    }
  }

  Future<void> _startWorker(Completer<void> ready) async {
    // Load and decompress on the main isolate's *IO*, then hand the decoded
    // structure over once. rootBundle is not available inside a bare isolate.
    final data = await rootBundle.load('assets/gtfs/routes.json.gz');
    final decoded = await compute(
        _decode, data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));

    final receive = ReceivePort();
    _receive = receive;
    // onExit/onError are load-bearing: they are the ONLY signal that a worker
    // died during the graph build, before it could send its SendPort back.
    // Completing `ready` with an error there converts a permanent hang into an
    // ordinary failure that plan() already knows how to absorb.
    final died = ReceivePort();
    died.listen((_) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('routing worker died during startup'));
      } else if (_isolate != null) {
        // Died AFTER a good start (e.g. the OS reclaimed it under memory
        // pressure). _send now points at a dead port, so tear down rather than
        // let every later search burn its full 12 s query timeout; the next
        // plan() respawns a fresh worker.
        dispose();
      }
    });
    _died = died;
    _isolate = await Isolate.spawn(
      _entry,
      [receive.sendPort, decoded],
      onExit: died.sendPort,
      onError: died.sendPort,
      errorsAreFatal: true,
    );

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
    _died?.close();
    _died = null;
    _send = null;
    // Cleared so a failed start is RETRYABLE — a stale completer here is what
    // made a single bad start brick routing for the whole session.
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
