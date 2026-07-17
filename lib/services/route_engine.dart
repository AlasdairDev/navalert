import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../models/models.dart';

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
  List<RouteSuggestion> buildSuggestions({
    required String tripId,
    required String originLabel,
    required String destinationLabel,
    required double distanceKm,
    required TransportPreferences prefs,
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

    if (options.isEmpty) return [];

    // Keep the two fastest options, then tag ONLY the kept ones —
    // otherwise the Cheapest/Costly tags could point at a dropped
    // option and never appear on screen (Figure 22).
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
