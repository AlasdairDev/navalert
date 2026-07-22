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

  /// Where this leg ends. Present only for GTFS-matched legs; null for the
  /// synthetic fallback, whose "stops" are fictional points on a straight line.
  final double? endLat;
  final double? endLng;

  const GuideLeg({required this.step, this.endLat, this.endLng});

  /// Whether this leg can complete itself from GPS alone. Synthetic legs
  /// cannot: auto-advancing one would invent a location the rider never passes.
  bool get canAutoAdvance => endLat != null && endLng != null;
}
