import 'models.dart';

/// One leg of the commute guide as it exists **during** a trip.
///
/// Runtime-only: this is NOT a Data Dictionary table and is never persisted.
/// It deliberately has no `toMap()`/`fromMap()`, so nothing about it can reach
/// SQLite by accident.
///
/// It exists because Table 24 (`route_steps`) stores stop *names* only, with no
/// latitude or longitude — and we are not changing the schema. The coordinates
/// are already computed at planning time (`GtfsRouteMatch` carries `GtfsStop`
/// values with lat/lng) and were previously discarded. Since a trip is planned
/// and started in the same session, holding them in memory for the duration of
/// the trip is enough to drive geographic step-advancement.
class GuideLeg {
  final RouteStep step;

  /// Where this leg begins. Present for GTFS-matched legs and for the first
  /// leg of any route (which always starts at the trip's origin); null for
  /// synthetic middle legs, whose "transfer points" are fictional.
  ///
  /// Carried for DRAWING, not for advancement — a leg is completed by reaching
  /// its END, never by standing at its start.
  final double? startLat;
  final double? startLng;

  /// Where this leg ends. Present for GTFS-matched legs and for the final walk
  /// (which always ends at the trip's destination); null for synthetic middle
  /// legs, whose "stops" are fictional points on a straight line.
  final double? endLat;
  final double? endLng;

  /// Road geometry for **this leg alone**, as `[lat, lng]` pairs.
  ///
  /// The trip map draws the leg the rider is on and nothing else, so each leg
  /// has to own its own line: one whole-journey polyline cannot be segmented
  /// after the fact, because nothing in it says where the jeepney ride stops
  /// and the walk to the door begins.
  ///
  /// Empty when no geometry could be resolved (offline with no bundled shape,
  /// or a synthetic leg between fictional points). The map then falls back to a
  /// straight start→end line, which is honest about being an approximation
  /// because it visibly ignores the road.
  final List<List<double>> path;

  const GuideLeg({
    required this.step,
    this.startLat,
    this.startLng,
    this.endLat,
    this.endLng,
    this.path = const [],
  });

  /// Whether this leg can complete itself from GPS alone. Synthetic legs
  /// cannot: auto-advancing one would invent a location the rider never passes.
  bool get canAutoAdvance => endLat != null && endLng != null;

  /// Whether this leg knows where it starts, and so can be drawn on its own.
  bool get hasStart => startLat != null && startLng != null;

  /// This leg with [path] attached. The geometry is resolved asynchronously
  /// (bundled shape lookup hits SQLite) long after the legs themselves are
  /// built, and RouteEngine is deliberately synchronous and storage-free — so
  /// the path is fitted afterwards rather than plumbed through the engine.
  GuideLeg withPath(List<List<double>> p) => GuideLeg(
        step: step,
        startLat: startLat,
        startLng: startLng,
        endLat: endLat,
        endLng: endLng,
        path: p,
      );
}
