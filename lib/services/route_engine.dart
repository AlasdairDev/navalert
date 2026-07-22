import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../models/guide_leg.dart';
import '../models/models.dart';
import 'gtfs_service.dart';

/// Commute guide engine (Requirement R6, Specific Objective 3).
///
/// Generates ranked PUV route suggestions with step-by-step commute
/// guidance and LTFRB-based fare estimation for jeepney, city bus and
/// UV Express, given an origin, a destination and the rider's mode
/// priority (Figure 21 — Mode Priority screen).
class RouteEngine {
  static const _uuid = Uuid();

  // LTFRB fare matrix (traditional PUV rates, PHP).
  static const double jeepBase = 13.0; // first 4 km
  static const double jeepPerKm = 1.80;
  static const double busBase = 15.0; // first 5 km (ordinary city bus)
  static const double busPerKm = 2.65;
  static const double uvBase = 15.0; // first 4 km
  static const double uvPerKm = 2.20;

  // Average Metro Manila in-traffic speeds (km/h) — Galvez et al. (2025)
  // report ~10.5 km/h average public-transport travel speed.
  static const double jeepKph = 11.0;
  static const double busKph = 15.0;
  static const double uvKph = 18.0;
  static const double walkKph = 4.5;
  static const double boardingWaitMin = 7.0; // headway/queueing buffer

  // Metro Manila (NCR) bounding box. The commute guide is only meaningful
  // inside it: the LTFRB fare matrix above is the Metro Manila rate structure
  // and the bundled GTFS feed covers NCR routes only. Producing a guide for a
  // trip to Baguio would invent both the route and the fare.
  static const double ncrMinLat = 14.30;
  static const double ncrMaxLat = 14.82;
  static const double ncrMinLng = 120.88;
  static const double ncrMaxLng = 121.18;

  /// Whether a point lies inside the serviceable Metro Manila area.
  static bool isWithinNcr(double lat, double lng) =>
      lat >= ncrMinLat &&
      lat <= ncrMaxLat &&
      lng >= ncrMinLng &&
      lng <= ncrMaxLng;

  double haversineKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return 2 * r * math.asin(math.min(1, math.sqrt(a)));
  }

  double _rad(double deg) => deg * math.pi / 180.0;

  double jeepFare(double km) =>
      km <= 4 ? jeepBase : jeepBase + (km - 4) * jeepPerKm;
  double busFare(double km) => km <= 5 ? busBase : busBase + (km - 5) * busPerKm;
  double uvFare(double km) => km <= 4 ? uvBase : uvBase + (km - 4) * uvPerKm;

  /// Builds up to two ranked suggestions honouring the mode priority.
  ///
  /// [legsOut] receives commute-guide legs with NO coordinates: these routes are
  /// synthetic, their legs are fractions of a straight line and their stops
  /// ("… Terminal", "Transfer point") are fictional. Such legs can only ever be
  /// advanced by the rider tapping — auto-advancing one would claim they passed
  /// a place that does not exist.
  List<RouteSuggestion> buildSuggestions({
    required String tripId,
    required String originLabel,
    required String destinationLabel,
    required double distanceKm,
    required TransportPreferences prefs,
    Map<String, List<GuideLeg>>? legsOut,
  }) {
    // Road distance ≈ 1.3 × straight-line distance in Metro Manila.
    final roadKm = math.max(0.5, distanceKm * 1.3);
    final anyEnabled =
        prefs.busEnabled || prefs.uvExpressEnabled || prefs.jeepneyEnabled;
    final useJeep = prefs.jeepneyEnabled || !anyEnabled;
    final useBus = prefs.busEnabled || !anyEnabled;
    final useUv = prefs.uvExpressEnabled || !anyEnabled;

    final options = <RouteSuggestion>[];

    // ---- Option A: jeepney-led (cheapest) ----
    if (useJeep) {
      options.add(_compose(
        tripId: tripId,
        label: 'Option A: ${_short(destinationLabel)} via Jeepney',
        originLabel: originLabel,
        destinationLabel: destinationLabel,
        legs: roadKm > 8
            ? [_Leg('jeepney', roadKm * 0.55), _Leg('jeepney', roadKm * 0.45)]
            : [_Leg('jeepney', roadKm)],
      ));
    }

    // ---- Option B: bus-led (fastest on long hauls) ----
    if (useBus) {
      options.add(_compose(
        tripId: tripId,
        label: 'Option B: ${_short(destinationLabel)} via Bus',
        originLabel: originLabel,
        destinationLabel: destinationLabel,
        legs: roadKm > 6 && useJeep
            ? [_Leg('bus', roadKm * 0.75), _Leg('jeepney', roadKm * 0.25)]
            : [_Leg('bus', roadKm)],
      ));
    }

    // ---- Option C: UV Express (direct, pricier) ----
    if (useUv && (options.length < 2 || roadKm > 10)) {
      options.add(_compose(
        tripId: tripId,
        label: 'Option ${String.fromCharCode(65 + options.length)}: '
            '${_short(destinationLabel)} via UV Express',
        originLabel: originLabel,
        destinationLabel: destinationLabel,
        legs: [_Leg('uv_express', roadKm)],
      ));
    }

    if (legsOut != null) {
      for (final o in options) {
        legsOut[o.suggestionId] =
            o.steps.map((s) => GuideLeg(step: s)).toList();
      }
    }
    return _tagPair(options);
  }

  /// Keeps the two fastest options and tags ONLY the kept ones with
  /// Fastest / Cheapest / Longest / Costly (Figure 22) — otherwise a tag
  /// could point at a dropped option and never appear on screen.
  List<RouteSuggestion> _tagPair(List<RouteSuggestion> options) {
    if (options.isEmpty) return [];
    options.sort((a, b) => a.totalDurationMinutes.compareTo(b.totalDurationMinutes));
    final kept = options.take(2).toList();
    final fastest = kept.first.suggestionId;
    final longest = kept.last.suggestionId;
    final byFare = [...kept]
      ..sort((a, b) => a.totalFarePhp.compareTo(b.totalFarePhp));
    final cheapest = byFare.first.suggestionId;
    final costly = byFare.last.suggestionId;

    final tagged = <RouteSuggestion>[];
    for (var i = 0; i < kept.length; i++) {
      final o = kept[i];
      String? tag1;
      String? tag2;
      if (o.suggestionId == fastest) tag1 = 'Fastest';
      if (o.suggestionId == cheapest) { tag1 == null ? tag1 = 'Cheapest' : tag2 = 'Cheapest'; }
      if (kept.length > 1 && o.suggestionId == longest) {
        tag1 == null ? tag1 = 'Longest' : tag2 ??= 'Longest';
      }
      if (kept.length > 1 && o.suggestionId == costly) {
        tag1 == null ? tag1 = 'Costly' : tag2 ??= 'Costly';
      }
      tagged.add(RouteSuggestion(
        suggestionId: o.suggestionId,
        tripId: o.tripId,
        rank: i + 1,
        routeLabel: o.routeLabel,
        tagPrimary: tag1,
        tagSecondary: tag2,
        totalFarePhp: o.totalFarePhp,
        totalDurationMinutes: o.totalDurationMinutes,
        transportSummary: o.transportSummary,
        steps: o.steps,
      ));
    }
    return tagged;
  }

  /// Builds ranked suggestions from REAL Metro Manila routes matched in the
  /// bundled GTFS feed (named routes + real boarding/alighting stops), with
  /// LTFRB fares on the actual ride distance. Falls back to the synthetic
  /// [buildSuggestions] when no GTFS route is matched.
  /// [legsOut], when supplied, receives the live commute-guide legs keyed by
  /// suggestion id. GTFS legs carry the real stop coordinates that would
  /// otherwise be discarded here, which is what lets the guide advance itself
  /// during the trip without adding coordinates to Table 24.
  List<RouteSuggestion> buildFromGtfs({
    required String tripId,
    required String destinationLabel,
    required List<GtfsRouteMatch> matches,
    Map<String, List<GuideLeg>>? legsOut,
  }) {
    final options = <RouteSuggestion>[];
    for (final m in matches) {
      final suggestionId = _uuid.v4();
      final walkToMin = math.max(1.0, m.walkToBoardM / (walkKph * 1000 / 60));
      final walkFromMin = math.max(1.0, m.walkFromAlightM / (walkKph * 1000 / 60));
      final kph = m.route.mode == 'bus' ? busKph : jeepKph;
      final rideMin = m.rideKm / kph * 60 + boardingWaitMin;
      final fare = m.route.mode == 'bus'
          ? busFare(m.rideKm)
          : jeepFare(m.rideKm);
      final noun = m.route.mode == 'bus' ? 'Bus' : 'Jeep';

      final steps = <RouteStep>[
        RouteStep(
          stepId: _uuid.v4(),
          suggestionId: suggestionId,
          stepNumber: 1,
          transportMode: 'walk',
          instruction: 'Walk to ${_short(m.boardStop.name)}',
          toStop: _short(m.boardStop.name),
          durationMinutes: walkToMin.roundToDouble(),
        ),
        RouteStep(
          stepId: _uuid.v4(),
          suggestionId: suggestionId,
          stepNumber: 2,
          transportMode: m.route.mode,
          instruction: 'Ride $noun "${m.route.name}" and alight at '
              '${_short(m.alightStop.name)} (~${m.rideKm.toStringAsFixed(1)} km)',
          fromStop: _short(m.boardStop.name),
          toStop: _short(m.alightStop.name),
          farePhp: _round(fare),
          durationMinutes: rideMin.roundToDouble(),
        ),
        RouteStep(
          stepId: _uuid.v4(),
          suggestionId: suggestionId,
          stepNumber: 3,
          transportMode: 'walk',
          instruction: 'Walk to ${_short(destinationLabel)}',
          toStop: _short(destinationLabel),
          durationMinutes: walkFromMin.roundToDouble(),
        ),
      ];

      // The walk-to-board leg ends at the boarding stop and the ride ends at
      // the alighting stop, both known precisely from the feed. The final walk
      // ends at the destination, whose coordinates are not passed in here, so
      // it stays manual — the destination alarm covers arrival anyway.
      legsOut?[suggestionId] = [
        GuideLeg(
            step: steps[0],
            endLat: m.boardStop.lat,
            endLng: m.boardStop.lng),
        GuideLeg(
            step: steps[1],
            endLat: m.alightStop.lat,
            endLng: m.alightStop.lng),
        GuideLeg(step: steps[2]),
      ];

      options.add(RouteSuggestion(
        suggestionId: suggestionId,
        tripId: tripId,
        rank: 0,
        routeLabel: '$noun: ${m.route.name}',
        totalFarePhp: _round(fare),
        totalDurationMinutes:
            (walkToMin + rideMin + walkFromMin).roundToDouble(),
        transportSummary: 'Walk + $noun',
        steps: steps,
      ));
    }
    return _tagPair(options);
  }

  RouteSuggestion _compose({
    required String tripId,
    required String label,
    required String originLabel,
    required String destinationLabel,
    required List<_Leg> legs,
  }) {
    final suggestionId = _uuid.v4();
    final steps = <RouteStep>[];
    var fare = 0.0;
    var minutes = 0.0;
    var stepNo = 1;

    // Walk to the boarding point.
    steps.add(RouteStep(
      stepId: _uuid.v4(),
      suggestionId: suggestionId,
      stepNumber: stepNo++,
      transportMode: 'walk',
      instruction: 'Walk towards the nearest ${_modeNoun(legs.first.mode)} '
          'boarding point near ${_short(originLabel)}',
      fromStop: _short(originLabel),
      durationMinutes: 4,
    ));
    minutes += 4;

    for (var i = 0; i < legs.length; i++) {
      final leg = legs[i];
      final legFare = switch (leg.mode) {
        'bus' => busFare(leg.km),
        'uv_express' => uvFare(leg.km),
        _ => jeepFare(leg.km),
      };
      final kph = switch (leg.mode) {
        'bus' => busKph,
        'uv_express' => uvKph,
        _ => jeepKph,
      };
      final legMin = leg.km / kph * 60 + boardingWaitMin;
      final from = i == 0 ? '${_short(originLabel)} Terminal' : 'Transfer point';
      final to = i == legs.length - 1
          ? 'near ${_short(destinationLabel)}'
          : 'Transfer point';
      steps.add(RouteStep(
        stepId: _uuid.v4(),
        suggestionId: suggestionId,
        stepNumber: stepNo++,
        transportMode: leg.mode,
        instruction: 'Ride a ${_modeNoun(leg.mode)} from $from and alight $to '
            '(~${leg.km.toStringAsFixed(1)} km)',
        fromStop: from,
        toStop: to,
        farePhp: _round(legFare),
        durationMinutes: legMin.roundToDouble(),
      ));
      fare += legFare;
      minutes += legMin;
    }

    // Walk to the final destination.
    steps.add(RouteStep(
      stepId: _uuid.v4(),
      suggestionId: suggestionId,
      stepNumber: stepNo++,
      transportMode: 'walk',
      instruction: 'Walk towards ${_short(destinationLabel)}',
      toStop: _short(destinationLabel),
      durationMinutes: 5,
    ));
    minutes += 5;

    final summary = ([
      'Walk',
      ...legs.map((l) => _modeNoun(l.mode)),
    ]).join(' + ');

    return RouteSuggestion(
      suggestionId: suggestionId,
      tripId: tripId,
      rank: 0,
      routeLabel: label,
      totalFarePhp: _round(fare),
      totalDurationMinutes: minutes.roundToDouble(),
      transportSummary: summary,
      steps: steps,
    );
  }

  double _round(double v) => (v * 4).ceil() / 4; // round up to ₱0.25

  String _modeNoun(String mode) => switch (mode) {
        'bus' => 'Bus',
        'uv_express' => 'UV Express',
        'walk' => 'Walk',
        _ => 'Jeep',
      };

  String _short(String label) {
    final first = label.split(',').first.trim();
    return first.length > 32 ? '${first.substring(0, 32)}…' : first;
  }
}

class _Leg {
  final String mode;
  final double km;
  _Leg(this.mode, this.km);
}
